# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # WHERE THE ADVANCE KEEPS THE GAME BOY'S SOUND CHIP (Backends::GameBoySound): each of the
        # chip's registers by what it does, as the address of the 16-bit register that holds it.
        module SoundRegisters
          H = Console::Hardware

          ADDRESSES = {
            square1_sweep: H::REG_SOUND1CNT_L, square1_control: H::REG_SOUND1CNT_H, square1_trigger: H::REG_SOUND1CNT_X,
            square2_control: H::REG_SOUND2CNT_L, square2_trigger: H::REG_SOUND2CNT_H,
            wave_switch: H::REG_SOUND3CNT_L, wave_level: H::REG_SOUND3CNT_H, wave_trigger: H::REG_SOUND3CNT_X,
            noise_control: H::REG_SOUND4CNT_L, noise_trigger: H::REG_SOUND4CNT_H,
            sound_power: H::REG_SOUNDCNT_X, speakers: H::REG_SOUNDCNT_L,
            **(0...GameBoySound::WAVE_WORDS).to_h { |word| [GameBoySound.wave_word(word), H::REG_WAVE_RAM + (word * 2)] }
          }.freeze

          module_function

          # +writes+ ([register, value] pairs of GameBoySound's) as [address, value] pairs.
          def at_addresses(writes) = writes.map { |register, value| [ADDRESSES.fetch(register), value] }
        end
      end
    end
  end
end
