# frozen_string_literal: true

require "test_helper"

# Where the processor's time went, by the address of each instruction, and how long the graphics chip
# spent drawing: the two counts a profiler reads (Core#take_processor_time, Core#gpu_busy_cycles).
class TestProcessorTime < Minitest::Test
  include HandMadeProgram

  # The sound chip makes a pair of samples every this many of the processor's cycles, so the samples
  # made over some frames say how many cycles those frames took, with nothing of the probe's in it.
  CYCLES_A_SAMPLE = 768

  # A fill of the whole 320 × 240 picture, once, then a loop doing nothing.
  private def filled_then_waiting
    words = ports +
            gp1(0x0000_0000) + gp1(0x0800_0001) + gp1(0x0300_0000) +
            gp0(0x0200_00F8) + gp0(0) + gp0((240 << 16) | 320)
    words + forever(LOAD_AT + (words.size * 4))
  end

  private def played(words)
    Dir.mktmpdir do |dir|
      core = RubyPS1Emulator::Core.new(write(dir, words))
      yield core
    ensure
      core&.destroy
    end
  end

  def test_the_first_ask_starts_the_count_and_answers_nothing
    played(filled_then_waiting) do |core|
      core.run_frame
      assert_empty core.take_processor_time
    end
  end

  # Every cycle of a frame of the loop is counted at the loop's two instructions, and the cycles add up
  # to the frames' length as the sound clock measures it.
  def test_a_frame_is_counted_at_the_instructions_it_ran
    played(filled_then_waiting) do |core|
      3.times { core.run_frame }
      core.take_processor_time
      samples = core.sound_frames
      4.times { core.run_frame }
      spent = core.take_processor_time
      loop_at = LOAD_AT + ((filled_then_waiting.size - 2) * 4)

      assert_equal [loop_at, loop_at + 4], spent.keys.sort
      measured = (core.sound_frames - samples) * CYCLES_A_SAMPLE
      assert_in_delta measured, spent.values.sum, measured * 0.01
    end
  end

  def test_the_graphics_chip_is_busy_only_while_it_draws
    played(filled_then_waiting) do |core|
      2.times { core.run_frame }
      drawn = core.gpu_busy_cycles
      4.times { core.run_frame }

      assert_operator drawn, :>, 0, "the fill took the chip's time"
      assert_equal drawn, core.gpu_busy_cycles, "the loop draws nothing"
    end
  end
end
