# frozen_string_literal: true

require "stringio"
require "test_helper"

# A `while` the game runs stops the picture and the buttons until it ends, unless something in it
# waits for the next frame, so one that never does earns a warning.
class TestIRGuardrailLoopNeverWaits < Minitest::Test
  private def warnings_of(frame_sync: :auto, &block)
    err = StringIO.new
    VBlank.build("PLAIN", console: :gba, frame_sync: frame_sync, out: StringIO.new, err: err, &block)
    err.string
  end

  # Nothing in it changes `n`, so once it starts it never ends.
  def test_a_while_whose_body_cannot_change_its_test_warns
    said = warnings_of do
      n = var(:n, 0)
      m = var(:m, 0)
      game_loop do
        while n >= 0
          m.increase!(1)
        end
      end
    end

    assert_includes said, "never waits for the next frame"
  end

  # Only a button can end it, and the buttons are read between frames.
  def test_a_while_on_a_button_with_no_frame_wait_warns
    said = warnings_of do
      m = var(:m, 0)
      game_loop do
        until pressed(:start)
          m.increase!(1)
        end
      end
    end

    assert_includes said, "never waits for the next frame"
  end

  # A test asked afresh on each round, its list read checked every time, that still reads
  # nothing the body changes.
  def test_a_while_joined_with_and_whose_body_cannot_change_its_test_warns
    said = warnings_of do
      marks = list :marks, capacity: 8, width: :byte, full_of: 0
      count = var(:count, 0)
      m = var(:m, 0)
      game_loop do
        while count < 5 && marks[count] != 9
          m.increase!(1)
        end
      end
    end

    assert_includes said, "never waits for the next frame"
  end

  # A counted loop is work done inside the pass, as `repeat` is.
  def test_a_counted_while_does_not_warn
    said = warnings_of do
      limit = var(:limit, 10)
      total = var(:total, 0)
      game_loop do
        i = 0
        while i < limit
          total.increase!(1)
          i += 1
        end
      end
    end

    refute_includes said, "never waits for the next frame"
  end

  def test_a_while_joined_with_and_that_moves_its_count_does_not_warn
    said = warnings_of do
      marks = list :marks, capacity: 8, width: :byte, full_of: 0
      game_loop do
        count = 0
        count += 1 while count < 5 && marks[count] != 9
      end
    end

    refute_includes said, "never waits for the next frame"
  end

  # Super Bomberman's stage layout: try again until a try succeeds, the flag cleared in the loop.
  def test_a_retry_loop_whose_body_clears_its_flag_does_not_warn
    said = warnings_of do
      tries = var(:tries, 0)
      func :place do
        placing = true
        while placing
          tries.increase!(1)
          placing = false if tries > 3
        end
      end
      game_loop { call :place }
    end

    refute_includes said, "never waits for the next frame"
  end

  # ...and the same with what ends it set in a routine the loop calls.
  def test_a_retry_loop_whose_called_routine_sets_its_test_does_not_warn
    said = warnings_of do
      tries = var(:tries, 0)
      done = var(:done, 0)
      func(:try_once) do
        tries.increase!(1)
        done.store!(1) if tries > 3
      end
      game_loop do
        done.store!(0)
        while done == 0
          call :try_once
        end
      end
    end

    refute_includes said, "never waits for the next frame"
  end

  def test_a_while_that_waits_does_not_warn
    said = warnings_of do
      n = 0
      game_loop do
        while n < 5
          n += 1
          wait_vblank
        end
      end
    end

    refute_includes said, "never waits for the next frame"
  end

  def test_a_while_that_waits_in_a_routine_it_calls_does_not_warn
    said = warnings_of(frame_sync: :manual) do
      n = 0
      func(:rest) { wait_vblank }
      game_loop do
        while n < 5
          n += 1
          call :rest
        end
        wait_vblank
      end
    end

    refute_includes said, "never waits for the next frame"
  end
end
