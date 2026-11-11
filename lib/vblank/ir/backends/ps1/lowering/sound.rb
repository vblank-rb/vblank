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
                                 play_sound_effect].freeze

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

            # WHAT A SONG DOES THAT THE PLAYSTATION'S PLAYER DOES NOT DO YET, in words, or nil: each is a step of
            # the Genesis's player (Genesis::Runtime::Music) still to be written for the R3000.
            def self.unmade_song_part(program)
              if SongTable.wobbles?(program) then "notes that wobble"
              elsif SongTable.steps_shapes?(program) then "notes that step their shapes"
              elsif SongTable.slides?(program) then "notes that slide"
              elsif SongTable.swells_under_level?(program) then "notes that swell under the music volume"
              elsif SongTable.any_note?(program) { |part, event| IR::Tunes.note_side(part, event) } then "notes from one speaker"
              elsif PS1::Music.new(program).recorded_parts? then "parts that play recordings"
              end
            end

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
              [asm.section, *(music_section if Sound.songs?(@program))]
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
            end

            # A song doing what the player does not do yet, refused by name.
            def refuse_unmade_song_parts!
              return unless Sound.songs?(@program)

              part = Sound.unmade_song_part(@program) or return
              raise NotMadeYet.new("This game's songs have #{part}. The #{CONSOLE.title} build does not make that yet. To fix " \
                                   "this, build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "sound: #{part}")
            end

            # The section of the game's songs (PS1::Music), each note's sound-log entries numbered among the rest.
            def music_section
              words = @music.words(sound_voicing) { |entry| sound_entry_number(entry) }
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
              emit_sound_entry([:beep, effect])
            end

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # Reference#exec_wave's entry.
            def emit_wave(node) = emit_sound_entry([:wave, { shape: node.shape, frequency: node.frequency, volume: node.volume }])
            def emit_stop_wave(_node) = emit_sound_entry([:stop_wave])

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
