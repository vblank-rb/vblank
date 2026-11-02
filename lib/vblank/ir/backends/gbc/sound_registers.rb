# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # WHERE THE COLOR KEEPS ITS SOUND CHIP, for the writes Backends::GameBoySound works out: the
        # Color's byte-wide registers, a value's two bytes going to two of them, and the runtime
        # writes them in a row (Runtime::Sound).
        module SoundRegisters
          H = Console::GBCHardware

          # The word of the wave voice's memory each write of it names.
          WAVE_WORDS = (0...GameBoySound::WAVE_WORDS).to_h { |word| [GameBoySound.wave_word(word), word] }.freeze

          module_function

          # +writes+ ([register, value] pairs) as a table of the Color's: each a register's low byte
          # and the byte for it, nought after the last.
          def table(writes) = [*writes.flat_map { |register, value| color_writes(register, value) }.flatten, 0]

          # One write as the Color's: a few of a value's bits are the Advance's alone (the second
          # bank of wave memory), and are left out.
          def color_writes(register, value)
            low = value & 0xFF
            high = value >> 8
            case register
            when :square1_sweep then [[H::NR10, low & 0x7F]]
            when :square1_control then [[H::NR11, low], [H::NR12, high]]
            when :square1_trigger then [[H::NR13, low], [H::NR14, high & 0xC7]]
            when :square2_control then [[H::NR21, low], [H::NR22, high]]
            when :square2_trigger then [[H::NR23, low], [H::NR24, high & 0xC7]]
            when :wave_switch then [[H::NR30, low & 0x80]]
            when :wave_level then [[H::NR31, low], [H::NR32, wave_level(value)]]
            when :wave_trigger then [[H::NR33, low], [H::NR34, high & 0xC7]]
            when :noise_control then [[H::NR41, low & 0x3F], [H::NR42, high]]
            when :noise_trigger then [[H::NR43, low], [H::NR44, high & 0xC0]]
            when :speakers then [[H::NR50, low & 0x77], [H::NR51, high]]
            when :sound_power then [[H::NR52, low & 0x80]]
            else
              at = H::WAVE_RAM + (WAVE_WORDS.fetch(register) * 2)
              [[at, low], [at + 1, high]]
            end.map { |at, byte| [at & 0xFF, byte] }
          end

          # The wave voice's loudness: full, a half and a quarter are the Color's own; three-quarters,
          # which the Color does not have, plays at full.
          def wave_level(value)
            return 1 << 5 if value[15] == 1

            ((value >> 13) & 3) << 5
          end
        end
      end
    end
  end
end
