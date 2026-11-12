# frozen_string_literal: true

require "test_helper"
require "brr_recordings"

# WHAT THE INTERPRETER MIXES of a recording given in the Super Nintendo sound chip's own format
# (Builder#sample's `brr:`): the samples the chip decodes, a byte each, sample for sample the same
# as the game given them by hand (BRRRecordings, fullsnes's arithmetic), round the loop. The
# computer builds are held to this mix by their checked runs; the Super Nintendo plays the bytes
# themselves (test/lowering/snes/vblank/ir/backends/snes/test_snes_brr_as_given.rb).
class TestBRRRecordingsInterpreter < Minitest::Test
  FRAMES = 6

  private def mixed
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      yield(self).play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    VBlank::IR::Backends::Reference.new.run(b.program, frames: FRAMES).mixed_sound
  end

  def test_every_filter_is_mixed_as_the_chip_decodes_it
    wanted = mixed { |b| b.sample :clip, pcm: BRRRecordings.chip_bytes(BRRRecordings::LOUD), rate: 8000 }

    assert(wanted.flatten.any?(&:nonzero?), "the recording is heard")
    assert_equal wanted, mixed { |b| b.sample :clip, brr: BRRRecordings::LOUD, rate: 8000 }
  end

  def test_a_loop_whose_times_round_take_turns_is_mixed_round_both
    wanted = BRRRecordings.chip_bytes(BRRRecordings::TAKING_TURNS, loop_at: 18, loops: 400)
    by_hand = mixed { |b| b.sample :clip, pcm: wanted, rate: 8000 }

    assert_equal by_hand, mixed { |b| b.sample :clip, brr: BRRRecordings::TAKING_TURNS, brr_loop: 18, rate: 8000 }
  end
end
