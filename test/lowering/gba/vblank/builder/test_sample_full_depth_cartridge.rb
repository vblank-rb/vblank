# frozen_string_literal: true

require "test_helper"
require "mixed_sound"
require "all/vblank/audio/test_wav_import"

# A 16-BIT RECORDING ON THE ADVANCE'S CARTRIDGE. The console's mixer plays eight bits, so its build
# keeps the high byte of each sample, the bytes it held before a game could give sixteen: the
# cartridge is the one built from those bytes, and it sounds as the interpreter's console mix says.
# The computer builds' sixteen bits are test/full_depth_sound_tests.rb's.
class TestSampleFullDepthCartridge < Minitest::Test
  include MixedSound
  include WavFiles

  RAMP = (0...256).map { |step| (step * 97) - 12_000 }.freeze

  private def ramp_game(pcm, bits)
    proc do
      screen :bitmap
      ramp = sample :ramp, pcm: pcm, bits: bits, rate: 8192
      ramp.play(loop: true)
      game_loop { wait_vblank }
    end
  end

  private def build(&block)
    VBlank.build("FULLDEPTH", console: :gba, out: nil, err: nil, &block)
  end

  def test_a_16_bit_recording_builds_the_cartridge_of_its_high_bytes
    full = build(&ramp_game(RAMP, 16))
    high = build(&ramp_game(RAMP.map { |level| level >> 8 }, 8))

    assert_equal high.buffer, full.buffer
  end

  # A stereo 16-bit WAV keeps the bytes it always had: each side's high byte, averaged.
  def test_a_16_bit_wav_builds_the_cartridge_it_always_did
    sides = RAMP.flat_map { |level| [level, 601 - level] }
    with_wav(wav_bytes(samples: sides, rate: 8192, bits: 16, channels: 2)) do |path|
      full = build do
        screen :bitmap
        sample(:ramp, from: path).play(loop: true)
        game_loop { wait_vblank }
      end
      bytes = sides.each_slice(2).map { |left, right| ((left >> 8) + (right >> 8)) / 2 }
      high = build(&ramp_game(bytes, 8))

      assert_equal high.buffer, full.buffer
    end
  end

  def test_a_16_bit_recording_sounds_on_the_cartridge_as_the_interpreter_mixes_it
    b = Builder.new
    b.instance_eval(&ramp_game(RAMP, 16))
    b.finalize_program

    assert_mixes_agree(b.program, frames: 12)
  end
end
