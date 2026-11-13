# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # SOUND, lowered for a Super Nintendo: each sound statement the S-DSP register writes its
          # entry of the interpreter's sound log means (DSPWrites), sent one at a time through the
          # sound unit's program (Runtime::Sound's rt_sound_write), and then the entry's number added
          # to the cartridge's own sound log (rt_sound_log), which a run reads back as the
          # interpreter's words (#sound_entries). Mixed into Lowering.
          module Sound
            STATEMENT_KINDS = %i[
              enable_sound beep noise wave stop_wave play_song stop_music hold_music play_from_list
              play_sound_effect play_sample stop_sample
            ].freeze

            def emit_sound_statement(node)
              case node.kind
              when :enable_sound then emit_enable_sound(node)
              when :beep then emit_beep(node)
              when :noise then emit_noise(node)
              when :wave then emit_wave(node)
              when :stop_wave then emit_stop_wave(node)
              when :play_song then emit_play_song(node)
              when :stop_music then emit_stop_music(node)
              when :hold_music then emit_hold_music(node)
              when :play_from_list then emit_play_from_list(node)
              when :play_sound_effect then emit_play_sound_effect(node)
              when :play_sample then emit_play_sample(node)
              when :stop_sample then emit_stop_sample(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # A recording's step (IR::Mixing.step: samples of it a sample of the DSP's, in 65536ths) as
            # the pitch register (fullsnes: $1000 reads one sample of a recording each of the DSP's).
            RECORDING_STEP_TO_PITCH = (1 << VBlank::Audio::Sound::STEP_SHIFT) / DSPWrites::PITCH_ONE

            # What the plays are to the author, for a cartridge too full for them.
            PLAYS = W65816::Holding.new(what: "the game's recordings", fix: "play fewer different recordings")

            # Whether +program+ makes any sound: a program with none of these kinds is built without
            # the sound unit.
            def self.sounds?(program) = program.walk.any? { |node| STATEMENT_KINDS.include?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program) = program.walk.any? { |node| %i[song play_song stop_music hold_music play_from_list play_sound_effect].include?(node.kind) }

            # Whether +program+ holds its music, so its player looks (Runtime::Music::TUNE_HELD).
            def self.holds_music?(program) = program.walk.any? { |node| node.kind == :hold_music }

            # Whether +program+ plays recordings — of its own, or as a song's part — and so carries their
            # count (Runtime::Recordings).
            def self.samples?(program)
              program.walk.any? { |node| node.kind == :play_sample } ||
                program.walk.any? { |node| node.kind == :song && node.voices.any? { |part| IR::Tunes.part_kind(part) == :recorded } }
            end

            # Whether +program+ has a recording shaped by the sound chip's own envelope bytes
            # (Audio::SNESEnvelope), whose voice is then told them (Runtime::Recordings::CHIP_ENVELOPES):
            # a recording declared with them, or a song's part or note given them.
            def self.chip_envelopes?(program)
              program.walk.any? do |node|
                next node.chip_envelope if node.kind == :sample
                next false unless node.kind == :song

                node.voices.any? do |part|
                  part.chip_envelope || part.events.any? { |event| event[VBlank::Audio::Music::Part::CHIP_ENVELOPE_SLOT] }
                end
              end
            end

            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # The game's recordings as the sound unit keeps them (Samples.recording, or Samples.brr_as_given
            # for one in the chip's own format), each once for every way it is played — through to its
            # end, or round from where it holds — in the order their source numbers follow the waves'.
            #
            # In a game that loads each scene's recordings, those every scene can play come first, and
            # then each scene's own, scene by scene (#scene_recording_loads), so the source numbers of
            # the recordings scenes load are the highest (Runtime::Sound, "Each scene's recordings").
            def sound_recordings
              recordings_in_source_order.map do |kept, back|
                kept.is_a?(VBlank::Audio::SNESRecording) ? Samples.brr_as_given(kept, back) : Samples.recording(kept, back)
              end
            end

            # SOME RECORDINGS ARE PLAYED BY ONE SCENE ALONE (#scene_of_recording), so a game whose
            # recordings do not all fit the sound unit's memory at once can be built loading them by
            # scene (SNES#build).
            def recordings_of_one_scene? = @recordings.any? { |kept, _| scene_of_recording(kept) }

            # For a game built loading each scene's recordings, a Runtime::Sound::SceneLoad for each
            # scene that has recordings of its own (#own_recordings?, which the scene's arrival was
            # lowered by), in the order #sound_recordings lists them; nil for any other game.
            def scene_recording_loads
              return nil unless @scene_recordings

              loads = @scenes.keys.select { |scene| own_recordings?(scene) }.map do |scene|
                count = @recordings.count { |kept, _| scene_of_recording(kept) == scene }
                raise ArgumentError, "the scene #{scene.inspect} plays recordings of its own and none was lowered" if count.zero?

                Runtime::Sound::SceneLoad.new(scene: scene, label: scene_recordings_label(scene), count: count)
              end
              loads unless loads.empty?
            end

            # WHAT A SCENE CHANGE COSTS, given once a build for each scene whose own recordings take
            # more than a frame to send (Runtime::Sound::BYTES_A_FRAME): the pass that scene takes
            # over on waits for them, and nothing else shows it.
            def scene_recording_findings
              loads = scene_recording_loads or return []
              own = sound_recordings.last(loads.sum(&:count))
              loads.filter_map do |load|
                bytes = own.shift(load.count).sum { |kept, _| kept.size }
                frames = bytes.ceildiv(Runtime::Sound::BYTES_A_FRAME)
                next if frames <= 1

                scene = Runtime::Sound.scene_name(load.scene)
                Guardrails::Finding.new(
                  check: :snes_scene_recordings_load, severity: :warning, node: @funcs.fetch(load.scene, :program),
                  message: "The scene #{scene} sends #{bytes} bytes of its own recordings to the Super Nintendo's " \
                           "sound memory when it starts. The game stops for about #{frames} frames while they go. " \
                           "To make this shorter, use shorter recordings in the scene #{scene}, or record them at " \
                           "a lower rate."
                )
              end
            end

            # The table of the recordings the scene the game opens on loads, sent at power-on; nil
            # where it has none, or the game does not load them by scene.
            def opening_scene_recordings_label
              scene = opening_scene
              scene_recordings_label(scene) if @scene_recordings && scene && own_recordings?(scene)
            end

            # The recordings' names, by the number a place playing one keeps (Runtime::Recordings).
            def recording_names = @samples.keys

            # The table of the game's plays, one row each (Runtime::Recordings), labelled "recording_plays";
            # and after it, in a game with a recording shaped by the chip's own envelope bytes, those
            # bytes a row each, labelled "recording_chip_envelopes"; and in a game with a recorded note
            # off the middle of the speakers, each play's two sides, a word a row, labelled
            # "recording_sides" (Runtime::Recordings::SIDES).
            def recordings_section
              asm = W65816.new("recording plays", holds: PLAYS)
              asm.label("recording_plays")
              moved = source_places_moved
              @plays.each { |row, _| asm.data_words(row_in_source_order(row, moved)) }
              asm.data_words(0) if @plays.empty? # a label has to be somewhere
              if Sound.chip_envelopes?(@program)
                asm.label("recording_chip_envelopes")
                @chip_envelopes.each { |row| asm.data_bytes(row) }
              end
              if IR::Tunes.recorded_pans?(@program)
                asm.label("recording_sides")
                @plays.each { |_, sides| asm.data_words(sides) }
              end
              asm.section
            end

            # The wave voice's waveforms this game plays, each at the loudness it plays it, in the
            # order they are recorded beside the sound program (Samples::FIRST_WAVE on).
            def sound_waves = @sound_waves.dup

            # What the DSP writes for this game's sound-log entries are worked out with.
            def sound_voicing = DSPWrites::Voicing.new(waves: @sound_waves, parts: @music.parts, effects: @music.effect_names)

            # The section of the game's songs (SNES::Music), each note's sound-log entries numbered
            # among the rest.
            def music_section
              words = @music.words(sound_voicing, recordings: self) do |entry|
                sound_entry_number(entry)
              end
              @music.section(words)
            end

            # Whether a song has a part that plays a recording, whose notes are played in the places
            # Runtime::Recordings keeps.
            def recorded_parts? = @music.recorded_parts?

            # THE ROW A NOTE OF A RECORDED PART PLAYS (Reference::Mixer#start_music_note): recording +name+
            # read at +frequency+, from its start, back to where it holds from at its end (or played
            # once, for one that does not hold), at its written +volume+ as a mixer voice's loudness,
            # shaped by +envelope+ (the note's or its part's), or by the recording's own when it has none:
            # and then by the chip's own envelope bytes, when the recording was given them. Where the
            # note's or its part's envelope was given as the chip's bytes, +chip_envelope+ is those
            # (an Audio::SNESEnvelope, +envelope+ then the nearest shape) and the voice is told them.
            # Nothing is logged as it comes round. Its number in "recording_plays". A note of a part
            # that glides +walks+ its samples, which every frame pays for while it sounds, since its
            # end cannot be counted ahead; every other note counts its frames. +pan+ is where the note
            # sits between the speakers (an Audio::Pan, nil for the middle; Runtime::Recordings::SIDES).
            def recorded_note_row(name, frequency, volume, envelope = nil, walks: false, chip_envelope: nil, pan: nil)
              declared = declared_sample(name)
              info = Assets::Sample.of(declared)
              clock = Console::SUPER_NINTENDO.sample_clock(declared.rate)
              back = info.loop_length
              step = IR::Mixing.step(info, frequency, clock.rate)
              refuse_unreadable_play!(name, step, back)
              source = source_of_recording(declared, back)
              row = Runtime::Recordings.row(
                source: source,
                pitch: [step / RECORDING_STEP_TO_PITCH, 1].max,
                volume: (IR::Tunes.mix_loudness(volume) * DSPWrites::VOICE_VOLUME_LOUDEST / IR::Tunes::MIX_FULL.to_f).round,
                length: info.length, back: back, advance: step * clock.samples_a_frame,
                logged: Runtime::Recordings::NOT_LOGGED, name: @samples.keys.index(name), shape: shape_of(envelope || info.envelope),
                walks: walks, chip_envelope: chip_envelope_number(envelope ? chip_envelope : declared.chip_envelope)
              )
              play_number(row, pan)
            end

            def declared_sample(name)
              @samples.fetch(name) { raise LoweringError, "the instrument #{name.inspect} is not declared" }
            end

            private

            def prepare_sound
              @sound_entries = []
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = SNES::Music.new(@program)
              verb_waves = @program.walk.select { |node| node.kind == :wave }.map { |node| wave_params(node) }
              @sound_waves = (verb_waves + @music.waves).map { |params| DSPWrites.wave_steps(params) }.uniq
              @samples = @program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
              @recordings = [] # [samples, read-back] for each recording the sound unit keeps (#source_of_recording)
              @plays = []      # each play's row of "recording_plays", and its word of "recording_sides"
              @chip_envelopes = [Runtime::Recordings::NO_CHIP_ENVELOPE] # each row of "recording_chip_envelopes"
            end

            # THE ONE SCENE THAT PLAYS THE SAMPLES +kept+ (a recording's samples, or its bytes in the
            # chip's format), or nil where something else can play them too. A recording is a scene's
            # own when every name it is declared under is played only from that scene's routine and
            # what it calls, and from nowhere else: not from the game loop or a routine it calls
            # outside the scenes, not from a timer's tick or a bend, and not from any song, which can
            # go on playing from one scene into the next. A scene that calls another scene's routine
            # reaches its recordings too, so those are kept by neither.
            def scene_of_recording(kept)
              (@scene_of_recording ||= {}.compare_by_identity).fetch(kept) do
                @scene_of_recording[kept] = only_scene_playing(kept)
              end
            end

            # #scene_of_recording, worked out: the scenes playing each name declared with +kept+, which
            # must all be the same one scene.
            def only_scene_playing(kept)
              names = @samples.values.select { |node| (node.chip_recording || node.bytes) == kept }.map(&:name)
              scenes = names.map { |name| scenes_playing_samples.fetch(name, []) }.uniq
              scenes.first.first if scenes.one? && scenes.first.one? && !scenes.first.first.nil?
            end

            # Each sample's name, beside the scenes that can play it, nil standing for anything outside
            # one: worked out once.
            def scenes_playing_samples
              @scenes_playing_samples ||= begin
                playing = Hash.new { |hash, name| hash[name] = [] }
                turns = scenes_taking_turns
                @scenes.each_key do |scene|
                  next unless @funcs.key?(scene)

                  owner = (scene if turns.include?(scene))
                  samples_played_from([@funcs.fetch(scene)]).each { |name| playing[name] |= [owner] }
                end
                elsewhere = [@program, *@tick_handlers.values, *@program.walk.select { |node| node.kind == :scroll_rows }]
                samples_played_from(elsewhere, past: @scenes.keys).each { |name| playing[name] |= [nil] }
                song_instrument_names.each { |name| playing[name] |= [nil] }
                playing
              end
            end

            # THE SCENES THAT TAKE TURNS: those one variable picks, never two up at once. A game can
            # pick scenes by more than one variable, and a scene another variable picks can be up
            # beside one of these, so only the variable picking the most scenes has its scenes keep
            # recordings of their own, less any scene another variable picks too; every other scene's
            # recordings stay in the sound unit throughout. A scene's routine called by name (`call`, or
            # a call picking from a list) runs without taking over, so its recordings would never be
            # sent: such a scene keeps none of its own either.
            def scenes_taking_turns
              picked = Hash.new { |hash, var| hash[var] = [] }
              called = []
              @program.walk.each do |node|
                case node.kind
                when :case then picked[node.var] |= node.clauses.map(&:last)
                when :call then called << node.target
                when :call_one_of then called.concat(node.targets)
                end
              end
              return [] if picked.empty?

              var, scenes = picked.max_by { |_, named| named.size }
              scenes - picked.reject { |other, _| other == var }.values.flatten - called
            end

            # The samples played by the statements under +roots+ and the routines they call, however
            # deep, not following a call into a routine named in +past+.
            def samples_played_from(roots, past: [])
              statements = Reach.statements_from(*roots)
              waiting = Reach.routines_named(statements) - past
              reached = []
              until waiting.empty?
                name = waiting.shift
                next if reached.include?(name) || !@funcs.key?(name)

                reached << name
                under = Reach.statements_under(@funcs.fetch(name))
                statements.concat(under)
                waiting.concat(Reach.routines_named(under) - past)
              end
              statements.select { |node| node.kind == :play_sample }.map(&:name).uniq
            end

            # Every name a song's parts or notes play as an instrument.
            def song_instrument_names
              @program.walk.select { |node| node.kind == :song }.flat_map do |song|
                song.voices.flat_map { |part| [part.instrument, *part.events.map { |event| event[2] }] }
              end.compact.uniq
            end

            # Whether +scene+ plays recordings of its own, from the program alone: a scene's arrival can
            # be lowered before the routines that play them.
            def own_recordings?(scene)
              scenes_playing_samples.any? do |name, scenes|
                node = @samples[name]
                node && scenes == [scene] && scene_of_recording(node.chip_recording || node.bytes) == scene
              end
            end

            def scene_recordings_label(scene) = "scene recordings of #{scene}"

            # #sound_recordings' order of the game's recordings: as they were first played, or in a game
            # that loads them by scene, those every scene can play and then each scene's own.
            def recordings_in_source_order
              return @recordings unless @scene_recordings

              always = @recordings.reject { |kept, _| scene_of_recording(kept) }
              always + @scenes.keys.flat_map { |scene| @recordings.select { |kept, _| scene_of_recording(kept) == scene } }
            end

            # A row of "recording_plays" with its source number in #sound_recordings' order. +moved+ is
            # each recording's place in that order, by its place in the order first played
            # (#source_places_moved).
            def row_in_source_order(row, moved)
              return row unless moved

              first = Samples::FIRST_WAVE + @sound_waves.size
              at = Runtime::Recordings::SOURCE / 2
              row.dup.tap { |words| words[at] = first + moved.fetch(row[at] - first) }
            end

            # Where each recording moved to in #sound_recordings' order, by its place in the order first
            # played; nil where nothing moved. Each recording is kept once (#source_of_recording), so its
            # place in either order is its own.
            def source_places_moved
              return nil unless @scene_recordings

              recordings_in_source_order.each_with_index.to_h { |kept, place| [@recordings.index(kept), place] }
            end

            # A scene taking over brings its own recordings into the sound unit, unless they are the
            # ones there (Runtime::Sound's rt_sound_load_scene). A scene with none leaves the last
            # scene's where they are.
            def emit_scene_recordings(scene)
              return unless @scene_recordings_up && own_recordings?(scene)

              number = Build.int(@scenes.fetch(scene))
              same = fresh("scene_recordings_up")
              jump_unless(Build.binop(:!=, Build.var_ref(@scene_recordings_up), number), same)
              statement(Build.set(@scene_recordings_up, number))
              runtime_call("rt_sound_load_scene", [LongAddress.new(scene_recordings_label(scene))])
              @asm.label(same)
            end

            # Which scene's own recordings are in the sound unit, in a game that loads them by scene:
            # from power-on, the scene the game opens on (Runtime#emit_start).
            def keep_scene_recordings_up
              scene = opening_scene
              @scene_recordings_up = keep_local(:scene_recordings_up, start: @scenes.fetch(scene)) if @scene_recordings && scene
            end

            # THE SOURCE NUMBER A PLAY OF THE RECORDING +declared+ READS, going +back+ at its end: the
            # next one the first time those samples are played that way.
            #
            # What the sound unit keeps of a recording is its samples and where it reads back to, and
            # nothing else: the rate it was recorded at and the note it plays are the voice's pitch
            # register, and its shape the voice's envelope registers, both written for each note
            # (Runtime::Recordings' row). So recordings declared under several names with the same
            # samples, as one instrument's recording played with several envelopes is, are kept
            # once, and every one of them reads the same source. Which recording a place holds is
            # still each one's own name (the row's NAME).
            #
            # A recording the game gave in the chip's own format (an Audio::SNESRecording) is kept as
            # those bytes (Samples.brr_as_given), however its samples compare with another's.
            def source_of_recording(declared, back)
              kept = [declared.chip_recording || declared.bytes, back]
              @recordings << kept unless @recordings.include?(kept)
              Samples::FIRST_WAVE + @sound_waves.size + @recordings.index(kept)
            end

            # The row of "recording_chip_envelopes" that holds +envelope+ (an Audio::SNESEnvelope's
            # three bytes, a recording's or a note's), the next row the first time; nought for nil.
            def chip_envelope_number(envelope)
              return 0 unless envelope

              row = Runtime::Recordings.chip_envelope_row(envelope)
              @chip_envelopes << row unless @chip_envelopes.include?(row)
              @chip_envelopes.index(row)
            end

            # Reference#exec_play_sample (Reference::Mixer#start): a row of the table for the play —
            # the voice's source, pitch and volume, and the count the interpreter's mix keeps for it —
            # and the runtime handed its number.
            def emit_play_sample(node)
              declared = @samples.fetch(node.name) { raise LoweringError, "the sample #{node.name.inspect} is not declared" }
              info = Assets::Sample.of(declared)
              clock = Console::SUPER_NINTENDO.sample_clock(declared.rate)
              frequency = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
              back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
              step = IR::Mixing.step(info, frequency, clock.rate)
              refuse_unreadable_play!(node.name, step, back)
              source = source_of_recording(declared, back)
              loudness = VBlank::Audio::Sound::MIX_LEVELS.fetch(node.volume, VBlank::Audio::Sound::MIX_LEVELS[:full])
              row = Runtime::Recordings.row(
                source: source,
                pitch: [step / RECORDING_STEP_TO_PITCH, 1].max,
                volume: (loudness * DSPWrites::VOICE_VOLUME_LOUDEST / VBlank::Audio::Sound::MIX_LEVELS[:full].to_f).round,
                length: info.length, back: back, advance: step * clock.samples_a_frame,
                logged: sound_entry_number([:sample, node.name]), name: @samples.keys.index(node.name),
                shape: shape_of(info.envelope), chip_envelope: chip_envelope_number(declared.chip_envelope)
              )
              runtime_call("rt_recordings_play", [Build.int(play_number(row, nil))])
            end

            # The number in "recording_plays" of a play of +row+ heard where +pan+ (an Audio::Pan, nil
            # for the middle) puts it: the next the first time the two are played together.
            def play_number(row, pan)
              play = [row, VBlank::Audio::Pan.shares_word(pan)]
              @plays << play unless @plays.include?(play)
              @plays.index(play)
            end

            # Reference#exec_stop_sample (Reference::Mixer#stop): the recording's places freed, or every place.
            def emit_stop_sample(node)
              name = node.name ? @samples.keys.index(node.name) : Runtime::Recordings::ALL
              runtime_call("rt_recordings_stop", [Build.int(name), Build.int(sound_entry_number([:stop_sample]))])
            end

            # The loudness shape a play climbs and falls by (Reference::Mixer#recording_fields): the
            # envelope it was given, unless that envelope is plain and sounds flat out like none.
            def shape_of(envelope) = (envelope unless envelope.nil? || envelope.plain?)

            # A play the sound unit cannot keep with the interpreter's count: one read more than four
            # times as fast as the DSP plays (fullsnes: the pitch register reads at most $3FFF), and
            # one so fast that a single sample of the mix goes past the whole part a recording holds
            # (the interpreter logs that once, where the cartridge's count would log each time round).
            def refuse_unreadable_play!(name, step, back)
              if step / RECORDING_STEP_TO_PITCH > DSPWrites::PITCH_TOP
                raise LoweringError, "The sample #{name.inspect} plays more than four times faster than its recording. A " \
                                     "Super Nintendo cannot read a recording that fast. To fix this, play it at a " \
                                     "lower note."
              end
              return unless back.positive? && step > (back << VBlank::Audio::Sound::STEP_SHIFT)

              raise LoweringError, "The sample #{name.inspect} plays so fast that one step goes past the whole part it " \
                                   "holds. To fix this, hold it from an earlier point, or play it at a lower note."
            end

            # Reference#exec_play_song: the tune named, from the next frame or from here.
            def emit_play_song(node)
              routine = node.this_frame ? "rt_music_play_now" : "rt_music_play"
              runtime_call(routine, [Build.int(@music.number(node.name))])
            end

            def emit_stop_music(_node) = runtime_call("rt_music_stop", [])
            def emit_hold_music(node) = runtime_call(node.held ? "rt_music_hold_tune" : "rt_music_release_tune", [])

            # Reference#exec_play_from_list: the song at the place the game works out, of the list.
            def emit_play_from_list(node)
              routine = node.this_frame ? "rt_music_play_from_list_now" : "rt_music_play_from_list"
              runtime_call(routine, [node.which, Build.int(@music.list_number(node.name))])
            end

            # Reference#exec_play_sound_effect: the effect at the place the game works out, of the list.
            def emit_play_sound_effect(node)
              routine = node.this_frame ? "rt_sfx_play_now" : "rt_sfx_play"
              runtime_call(routine, [node.which, Build.int(@music.effect_list_number(node.name))])
            end

            # Reference#exec_wave's entry.
            def wave_params(node) = { shape: node.shape, frequency: node.frequency, volume: node.volume }

            def emit_wave(node)
              emit_game_sound_on(Reference::Player::WAVE_CHANNEL)
              emit_sound_entry([:wave, wave_params(node)])
            end

            def emit_stop_wave(_node)
              emit_game_sound_on(Reference::Player::WAVE_CHANNEL)
              emit_sound_entry([:stop_wave])
            end

            # Reference::Player#game_sound_on: a note of a song's wobbles no more on +channel+.
            def emit_game_sound_on(channel)
              runtime_call("rt_music_stop_wobble", [Build.int(channel)]) if Music.wobbles?(@program)
              runtime_call("rt_music_stop_shapes", [Build.int(channel)]) if Music.steps_shapes?(@program)
              runtime_call("rt_music_stop_swell", [Build.int(channel)]) if Music.swells_under_level?(@program)
            end

            # Reference#exec_enable_sound.
            def emit_enable_sound(_node) = emit_sound_entry([:enabled, *@program.main_volume])

            # Reference#exec_beep: the beep resolved as the interpreter resolves it.
            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                                      volume: node.volume, defined: @defined_sounds)
              emit_game_sound_on(Reference::Player::BEEP_CHANNEL)
              emit_sound_entry([:beep, effect])
            end

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # +entry+'s DSP writes, then its number into the cartridge's sound log.
            def emit_sound_entry(entry)
              DSPWrites.for_entry(entry, sound_voicing).each do |write|
                command, *numbers = Runtime::Sound.command_for(write)
                runtime_call(Runtime::Sound::ROUTINES.fetch(command), numbers.map { |number| Build.int(number) })
              end
              runtime_call("rt_sound_log", [Build.int(sound_entry_number(entry))])
            end

            # The number the cartridge's sound log keeps +entry+ as, the next one the first time.
            def sound_entry_number(entry)
              @sound_entry_numbers ||= {}
              @sound_entry_numbers[entry] ||= (@sound_entries << entry).size - 1
            end
          end
        end
      end
    end
  end
end
