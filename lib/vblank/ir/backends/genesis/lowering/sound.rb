# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # SOUND, lowered for a Genesis: each sound statement the chip writes its entry of the interpreter's
          # sound log means (ChipWrites), each made by a call of the runtime's (Runtime::Sound), and then the
          # entry's number added to the cartridge's own sound log (rt_sound_log), which a run reads back as
          # the interpreter's words (#sound_entries). Mixed into Lowering.
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

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| STATEMENT_KINDS.include?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program)
              program.walk.any? { |node| %i[song play_song stop_music hold_music play_from_list play_sound_effect].include?(node.kind) }
            end

            # Whether +program+ holds its music, so its player looks (Runtime::Music::TUNE_HELD).
            def self.holds_music?(program) = program.walk.any? { |node| node.kind == :hold_music }

            # What the plays and the recordings are to the author, for a cartridge too full for them.
            PLAYS = M68000::Holding.new(what: "the game's recordings", fix: "play fewer different recordings, or shorter ones")
            
            # Whether +program+ plays recordings, of its own or as a song's part, and so carries their count and
            # the sound processor's program (Runtime::Recordings).
            def self.samples?(program)
              program.walk.any? { |node| node.kind == :play_sample } ||
                program.walk.any? { |node| node.kind == :song && node.voices.any? { |part| IR::Tunes.part_kind(part) == :recorded } }
            end
            
            # The table of the game's plays, one row each (Runtime::Recordings), labelled "recording_plays", and
            # each recording it plays, as the bytes the DAC takes: from nought to 255, the middle quiet.
            def recordings_sections
              table = M68000.new("recording plays", holds: PLAYS)
              table.label("recording_plays")
              @plays.each do |name, length, back, advance, logged, step|
                Runtime::Recordings.emit_row(table, start: recording_label(name), length: length, back: back, advance: advance, logged: logged,
                                                    name: @samples.keys.index(name), step: step)
              end
              table.data_words(0) if @plays.empty? # a label has to be somewhere
              [table.section, *@plays.map { |name, *| recording_kept_as(name) }.uniq.map { |name| recording_section(name) }]
            end

            # The label of the bytes a play of recording +name+ reads.
            def recording_label(name) = "recording #{recording_kept_as(name)}"

            # THE RECORDING WHOSE BYTES THE CARTRIDGE KEEPS FOR +name+: the first one declared with the
            # same samples. A row of the table carries everything else about a play (how fast it is
            # read, where it goes back to, and which recording it is to the game), so recordings
            # declared under several names with the same samples read one copy of them.
            def recording_kept_as(name)
              bytes = @samples.fetch(name).bytes
              @samples.each_key.find { |other| @samples.fetch(other).bytes == bytes }
            end

            def recording_section(name)
              asm = M68000.new(recording_label(name), holds: PLAYS)
              asm.label(recording_label(name))
              asm.data_bytes(@samples.fetch(name).bytes.unpack("c*").map { |sample| sample + 128 })
              asm.section
            end
            
            # The recordings' names, by the number a place playing one keeps (Runtime::Recordings).
            def recording_names = @samples.keys
            
            # Whether a song has a part that plays a recording.
            def recorded_parts? = @music.recorded_parts?
            
            # THE ROW A NOTE OF A RECORDED PART PLAYS (Reference::Mixer#start_music_note): recording +name+ read at
            # +frequency+, from its start, back to where it holds from at its end. Nothing is logged as it comes
            # round. A Genesis plays a recording all or nothing, so a loudness is the log's alone, and a shape
            # is one thing it does not do yet. Its number in "recording_plays". +chip_envelope+ is
            # another console's sound chip's bytes for the shape, which nothing here reads.
            def recorded_note_row(name, frequency, _volume, envelope = nil, chip_envelope: nil)
              info = Assets::Sample.of(declared_sample(name))
              shape = envelope || info.envelope
              if shape && !shape.plain?
                raise NotMadeYet.new("The song part that plays #{name.inspect} has a shape (`envelope:`). The Genesis build does not make " \
                                     "that yet.", part: "recordings with a shape")
              end
            
              play_row(name, frequency, info.loop_length, Runtime::Recordings::NOT_LOGGED)
            end
            
            def declared_sample(name) = @samples.fetch(name) { raise LoweringError, "the instrument #{name.inspect} is not declared" }
            
            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # What the writes for this game's sound-log entries are worked out with.
            def sound_voicing = ChipWrites::Voicing.new(parts: @music.parts, effects: @music.effect_names)

            # The section of the game's songs (Genesis::Music), each note's sound-log entries numbered among
            # the rest.
            def music_section
              words = @music.words(sound_voicing, recordings: self) { |entry| sound_entry_number(entry) }
              @music.section(words)
            end

            private

            def prepare_sound
              @sound_entries = []
              @sound_entry_numbers = {}
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = Genesis::Music.new(@program)
              @samples = @program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
              @plays = [] # each play's row of "recording_plays"
            end
            
            # The row of a play of +name+ at +frequency+, going +back+ at its end and logging +logged+ as it comes
            # round: how fast it is read as the interpreter works it out (IR::Mixing.step), and how far that goes
            # in a frame. Its number.
            def play_row(name, frequency, back, logged)
              declared = declared_sample(name)
              info = Assets::Sample.of(declared)
              clock = Console::GENESIS.sample_clock(declared.rate)
              step = IR::Mixing.step(info, frequency, clock.rate)
              row = [name, info.length, back, step * clock.samples_a_frame, logged, Runtime::Recordings.z80_step(step, clock.rate)]
              @plays << row unless @plays.include?(row)
              @plays.index(row)
            end
            
            # Reference#exec_play_sample (Reference::Mixer#start).
            def emit_play_sample(node)
              info = Assets::Sample.of(declared_sample(node.name))
              frequency = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
              back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
              row = play_row(node.name, frequency, back, sound_entry_number([:sample, node.name]))
              runtime_call("rt_recordings_play", [Build.int(row)])
            end
            
            # Reference#exec_stop_sample (Reference::Mixer#stop): the recording's place freed, or the place.
            def emit_stop_sample(node)
              name = node.name ? @samples.keys.index(node.name) : Runtime::Recordings::ALL
              runtime_call("rt_recordings_stop", [Build.int(name), Build.int(sound_entry_number([:stop_sample]))])
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
              runtime_call("rt_music_stop_wobble", [Build.int(channel)]) if Genesis::Music.wobbles?(@program)
              runtime_call("rt_music_stop_shapes", [Build.int(channel)]) if Genesis::Music.steps_shapes?(@program)
              runtime_call("rt_music_stop_swell", [Build.int(channel)]) if Genesis::Music.swells_under_level?(@program)
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

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # +entry+'s chip writes, then its number into the cartridge's sound log.
            def emit_sound_entry(entry)
              ChipWrites.for_entry(entry, sound_voicing).each do |write|
                command, *numbers = Runtime::Sound.command_for(write)
                runtime_call(Runtime::Sound::ROUTINES.fetch(command), numbers.map { |number| Build.int(number) })
              end
              runtime_call("rt_sound_log", [Build.int(sound_entry_number(entry))])
            end

            # The number the cartridge's sound log keeps +entry+ as, the next one the first time.
            def sound_entry_number(entry) = @sound_entry_numbers[entry] ||= (@sound_entries << entry).size - 1
          end
        end
      end
    end
  end
end
