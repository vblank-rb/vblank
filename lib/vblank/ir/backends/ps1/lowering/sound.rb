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
          # the chip's sound memory as it starts. Mixed into Lowering.
          module Sound
            STATEMENT_KINDS = %i[enable_sound beep noise wave stop_wave].freeze

            def emit_sound_statement(node)
              case node.kind
              when :enable_sound then emit_enable_sound(node)
              when :beep then emit_beep(node)
              when :noise then emit_noise(node)
              when :wave then emit_wave(node)
              when :stop_wave then emit_stop_wave(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| STATEMENT_KINDS.include?(node.kind) }

            # Every entry of the sound log the program can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # What sound memory holds for this program, or nil for one that makes no sound.
            attr_reader :sound_memory

            # Whether this program makes sound, and so carries the runtime's Sound.
            def sound? = !@sound_memory.nil?

            # The loops, as the section the runtime copies from "sound_memory" to "sound_memory_end".
            def sound_memory_sections
              return [] unless sound?

              asm = R3000.new("sound memory", holds: TABLES_HOLDING)
              asm.label("sound_memory")
              asm.data_bytes(@sound_memory.bytes.bytes)
              asm.label("sound_memory_end")
              [asm.section]
            end

            private

            def prepare_sound
              @sound_entries = []
              @sound_entry_numbers = {}
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @sound_memory = Sound.sounds?(@program) ? SoundMemory.new(@program) : nil
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

            # +entry+'s writes, then its number into the program's sound log.
            def emit_sound_entry(entry)
              SPUWrites.for_entry(entry, @sound_memory).each do |write|
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
