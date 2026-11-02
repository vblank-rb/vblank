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
            STATEMENTS = Ractor.make_shareable({ enable_sound: :emit_enable_sound, beep: :emit_beep, noise: :emit_noise,
                                                 wave: :emit_wave, stop_wave: :emit_stop_wave, play_song: :emit_play_song,
                                                 stop_music: :emit_stop_music, hold_music: :emit_hold_music,
                                                 play_from_list: :emit_play_from_list,
                                                 play_sound_effect: :emit_play_sound_effect })

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| STATEMENTS.key?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program)
              program.walk.any? { |node| %i[song play_song stop_music hold_music play_from_list play_sound_effect].include?(node.kind) }
            end

            # Whether +program+ holds its music, so its player looks (Runtime::Music::TUNE_HELD).
            def self.holds_music?(program) = program.walk.any? { |node| node.kind == :hold_music }

            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # What the writes for this game's sound-log entries are worked out with.
            def sound_voicing = ChipWrites::Voicing.new(parts: @music.parts, effects: @music.effect_names)

            # The section of the game's songs (Genesis::Music), each note's sound-log entries numbered among
            # the rest.
            def music_section
              words = @music.words(sound_voicing, recording_row: method(:recorded_note_row)) { |entry| sound_entry_number(entry) }
              @music.section(words)
            end

            # A note of a part that plays a recording, which this build does not make yet.
            def recorded_note_row(name, *)
              raise NotMadeYet.new("The song part that plays #{name.inspect} is not made yet. The Genesis build does not " \
                                   "make recordings yet.", part: "recordings")
            end

            private

            def prepare_sound
              @sound_entries = []
              @sound_entry_numbers = {}
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = Genesis::Music.new(@program)
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
