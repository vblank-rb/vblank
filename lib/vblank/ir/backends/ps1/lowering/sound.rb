# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # SOUND, lowered for a PlayStation: each sound statement makes the writes its entry of the
          # interpreter's sound log means (SPUWrites), each a call of the runtime's (Runtime::Sound), and then the
          # entry's number added to the program's own sound log (rt_sound_log), which a run reads back as the
          # interpreter's words (#sound_entries). The loops the voices play are made while building
          # (SoundMemory) and go in the program as the section "sound_memory", which the runtime copies into
          # the chip's sound memory as it starts. A game's songs and sound effects are a table (PS1::Music) its
          # player walks (Runtime::Music). Mixed into Lowering.
          module Sound
            STATEMENT_KINDS = %i[enable_sound beep noise wave stop_wave play_song stop_music hold_music play_from_list
                                 play_sound_effect play_sample stop_sample].freeze

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

            # Whether +program+ plays recordings of its own, and so carries their count (Runtime::Recordings).
            def self.samples?(program) = program.walk.any? { |node| node.kind == :play_sample } || recorded_parts?(program)

            # Whether a song of +program+ has a part that plays a recording, whose notes are played in
            # Runtime::Recordings' places.
            def self.recorded_parts?(program) = songs?(program) && PS1::Music.new(program).recorded_parts?

            # What the plays are to the author, for a program too full for them.
            PLAYS = R3000::Holding.new(what: "the game's recordings", fix: "play fewer different recordings")

            # The table of the game's plays, one row each (Runtime::Recordings), labelled "recording_plays";
            # and in a game with a recorded note off the middle of the speakers, each play's two sides, a word
            # a row, labelled "recording_sides" (Runtime::Recordings::SIDES).
            def recordings_section
              asm = R3000.new("recording plays", holds: PLAYS)
              asm.label("recording_plays")
              @plays.each { |row, _| asm.data_words(row) }
              asm.data_words(0) if @plays.empty? # a label has to be somewhere
              if IR::Tunes.recorded_pans?(@program)
                asm.label("recording_sides")
                @plays.each { |_, sides| asm.data_words(sides) }
              end
              asm.section
            end

            # The recordings' names, by the number a place playing one keeps (Runtime::Recordings).
            def recording_names = @samples.keys

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| STATEMENT_KINDS.include?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program)
              program.walk.any? { |node| %i[song play_song stop_music hold_music play_from_list play_sound_effect].include?(node.kind) }
            end

            # Whether +program+ holds its music, so its player looks (Runtime::Music::TUNE_HELD).
            def self.holds_music?(program) = program.walk.any? { |node| node.kind == :hold_music }

            # Every entry of the sound log the program can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # What sound memory holds for this program, or nil for one that makes no sound.
            attr_reader :sound_memory

            # Whether this program makes sound, and so carries the runtime's Sound.
            def sound? = !@sound_memory.nil?

            # What the writes for this game's sound-log entries are worked out with.
            def sound_voicing = SPUWrites::Voicing.new(memory: @sound_memory, parts: @music.parts, effects: @music.effect_names)

            # The loops, as the section the runtime copies from "sound_memory" to "sound_memory_end"; and the
            # song table, for a game with songs.
            def sound_sections
              return [] unless sound?

              asm = R3000.new("sound memory", holds: TABLES_HOLDING)
              asm.label("sound_memory")
              asm.data_bytes(@sound_memory.bytes.bytes)
              asm.label("sound_memory_end")
              [asm.section, *(music_section if Sound.songs?(@program)), *(recordings_section if Sound.samples?(@program))]
            end

            # How many sound effects the game has.
            def effect_count = Sound.songs?(@program) ? @music.effect_count : 0

            private

            def prepare_sound
              @sound_entries = []
              @sound_entry_numbers = {}
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @sound_memory = Sound.sounds?(@program) ? SoundMemory.new(@program) : nil
              @music = PS1::Music.new(@program)
              @samples = @program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
              @plays = [] # each play's row of "recording_plays"
            end

            # Reference#exec_play_sample (Reference::Mixer#start): a row of the table for the play — where its
            # recording starts in sound memory, the voice's pitch and volume, and the count the interpreter's
            # mix keeps for it — and the runtime handed its number.
            def emit_play_sample(node)
              info = Assets::Sample.of(declared_sample(node.name))
              frequency = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
              back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
              loudness = VBlank::Audio::Sound::MIX_LEVELS.fetch(node.volume, VBlank::Audio::Sound::MIX_LEVELS[:full])
              row = play_row(node.name, frequency, back, loudness, info.envelope, sound_entry_number([:sample, node.name]))
              runtime_call("rt_recordings_play", [Build.int(row)])
            end

            public

            # THE ROW A NOTE OF A RECORDED PART PLAYS (Reference::Mixer#start_music_note, SongTable asks it):
            # recording +name+ read at +frequency+, from its start, back to where it holds from at its end (or
            # once through, for one that does not hold), at its written +volume+ as a mix's loudness, shaped by
            # +envelope+ (the note's or its part's), or by the recording's own when it has none. Nothing is
            # logged as it comes round. A Super Nintendo envelope's own bytes (+chip_envelope+) are the Super
            # Nintendo's: here the note is shaped by the nearest envelope, which +envelope+ already is. +pan+ is
            # where it sits between the speakers (an Audio::Pan, nil for the middle; Runtime::Recordings::SIDES).
            # Its number in "recording_plays".
            def recorded_note_row(name, frequency, volume, envelope = nil, walks: false, chip_envelope: nil, pan: nil)
              _ = [walks, chip_envelope]
              info = Assets::Sample.of(declared_sample(name))
              play_row(name, frequency, info.loop_length, IR::Tunes.mix_loudness(volume), envelope || info.envelope,
                       Runtime::Recordings::NOT_LOGGED, pan: pan)
            end

            def declared_sample(name) = @samples.fetch(name) { raise LoweringError, "the sample #{name.inspect} is not declared" }

            private

            # The row of a play of +name+ at +frequency+, going +back+ at its end, at +loudness+ out of the mix's
            # full, shaped by +envelope+ (nil or plain for none), logging +logged+ as it comes round: where its
            # recording is in sound memory, the voice's pitch and loudness at full, and the count the
            # interpreter's mix keeps. Its number in "recording_plays", the same one for a play alike and heard
            # where +pan+ puts it alike.
            def play_row(name, frequency, back, loudness, envelope, logged, pan: nil)
              declared = declared_sample(name)
              info = Assets::Sample.of(declared)
              clock = CONSOLE.sample_clock(declared.rate)
              step = IR::Mixing.step(info, frequency, clock.rate)
              refuse_unreadable_play!(name, step, back)
              advance = step * clock.samples_a_frame
              shape = envelope unless envelope.nil? || envelope.plain?
              row = [@sound_memory.start_of(SoundMemory.recording(name, back)), recording_pitch(step),
                     (loudness * SPUWrites::LOUDEST) / IR::Tunes::MIX_FULL, info.length, back,
                     advance >> VBlank::Audio::Sound::STEP_SHIFT, advance & ((1 << VBlank::Audio::Sound::STEP_SHIFT) - 1),
                     logged, @samples.keys.index(name), shape ? shape.packed : 0]
              play = [row, VBlank::Audio::Pan.shares_word(pan)]
              @plays << play unless @plays.include?(play)
              @plays.index(play)
            end

            # Reference#exec_stop_sample (Reference::Mixer#stop): the recording's places freed, or every place.
            def emit_stop_sample(node)
              name = node.name ? @samples.keys.index(node.name) : Runtime::Recordings::ALL
              runtime_call("rt_recordings_stop", [Build.int(name), Build.int(sound_entry_number([:stop_sample]))])
            end

            # THE VOICE'S PITCH for a play read +step+ samples of its recording for each of the mix's, in
            # 65536ths: the chip reads 4096ths of a sample for each of its 44100 a second, which is the rate
            # the mix runs at (Console::Description#recording_voice_hz), so a sixteenth of the step.
            def recording_pitch(step) = (step / 16.0).round.clamp(1, SPUWrites::PITCH_TOP)

            # A play the chip cannot read with the interpreter's count: one read more than four times as fast
            # as the chip plays (its pitch register reads at most 3FFFh, Beetle PSX spu.c), and one so fast
            # that a single sample of the mix goes past the whole part a recording holds (the interpreter logs
            # that once, where the program's count would log each time round).
            def refuse_unreadable_play!(name, step, back)
              if step / 16.0 > SPUWrites::PITCH_TOP
                raise LoweringError, "The sample #{name.inspect} plays more than four times faster than its recording. A " \
                                     "PlayStation cannot read a recording that fast. To fix this, play it at a lower note."
              end
              return unless back.positive? && step > (back << VBlank::Audio::Sound::STEP_SHIFT)

              raise LoweringError, "The sample #{name.inspect} plays so fast that one step goes past the whole part it " \
                                   "holds. To fix this, hold it from an earlier point, or play it at a lower note."
            end

            # The section of the game's songs (PS1::Music), each note's sound-log entries numbered among the rest.
            def music_section
              words = @music.words(sound_voicing, recordings: self) { |entry| sound_entry_number(entry) }
              @music.section(words)
            end

            # Reference#exec_enable_sound.
            def emit_enable_sound(_node)
              runtime_call("rt_sound_on", [])
              emit_sound_entry([:enabled])
            end

            # Reference#exec_beep: the beep resolved as the interpreter resolves it.
            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                                      volume: node.volume, defined: @defined_sounds)
              emit_game_sound_on(Reference::Player::BEEP_CHANNEL)
              emit_sound_entry([:beep, effect])
            end

            # Reference::Player#game_sound_on: a song's note on +channel+ no longer wobbles, steps or swells.
            def emit_game_sound_on(channel)
              return unless Sound.songs?(@program)

              runtime_call("rt_music_stop_wobble", [Build.int(channel)]) if PS1::Music.wobbles?(@program)
              runtime_call("rt_music_stop_shapes", [Build.int(channel)]) if PS1::Music.steps_shapes?(@program)
              runtime_call("rt_music_stop_swell", [Build.int(channel)]) if PS1::Music.swells_under_level?(@program)
            end

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # Reference#exec_wave's entry.
            def emit_wave(node)
              emit_game_sound_on(Reference::Player::WAVE_CHANNEL)
              emit_sound_entry([:wave, { shape: node.shape, frequency: node.frequency, volume: node.volume }])
            end

            def emit_stop_wave(_node)
              emit_game_sound_on(Reference::Player::WAVE_CHANNEL)
              emit_sound_entry([:stop_wave])
            end

            # Reference#exec_play_song: the tune named, from the next frame or from here.
            def emit_play_song(node)
              runtime_call(node.this_frame ? "rt_music_play_now" : "rt_music_play", [Build.int(@music.number(node.name))])
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
              runtime_call(node.this_frame ? "rt_sfx_play_now" : "rt_sfx_play", [node.which, Build.int(@music.effect_list_number(node.name))])
            end

            # +entry+'s writes, then its number into the program's sound log.
            def emit_sound_entry(entry)
              SPUWrites.for_entry(entry, sound_voicing).each do |write|
                routine, numbers = Runtime::Sound.call_for(write)
                runtime_call(routine, numbers.map { |number| Build.int(number) })
              end
              runtime_call("rt_sound_log", [Build.int(sound_entry_number(entry))])
            end

            # The number the program's sound log keeps +entry+ as, the next one the first time.
            def sound_entry_number(entry) = @sound_entry_numbers[entry] ||= (@sound_entries << entry).size - 1
          end
        end
      end
    end
  end
end
