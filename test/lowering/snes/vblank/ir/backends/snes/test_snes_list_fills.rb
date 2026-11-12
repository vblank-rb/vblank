# frozen_string_literal: true

require "test_helper"

# A LIST SET TO ONE VALUE (Runtime::Lists rt_list_fill), held to the interpreter by the checked run:
# a list declared full of a value, a whole list filled and a run of it, for each width of slot, and
# a list whose first item has moved round its ring, so the run of slots it fills comes round to the
# first slot.
class TestSNESListFills < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  def test_lists_of_each_width_filled_whole_and_in_part_agree_with_the_interpreter
    run = SNES::CheckedRun.new.run(program_of do
      bytes = list :bytes, capacity: 7, width: :byte, full_of: 3
      halves = list :halves, capacity: 7, width: :half, full_of: -2
      words = list :words, capacity: 7, full_of: 70_000
      at = var :at, 2
      game_loop do
        bytes.fill 200, from: at, count: 3
        halves.fill(-40_000, from: at + 1, count: 4)
        words.fill(-123_456_789, from: at, count: 1)
      end
    end, frames: 2)

    assert_equal [3, 3, -56, -56, -56, 3, 3], run.list(:bytes)
    assert_equal [-2, -2, -2, 25_536, 25_536, 25_536, 25_536], run.list(:halves)
    assert_equal [70_000, 70_000, -123_456_789, 70_000, 70_000, 70_000, 70_000], run.list(:words)
  end

  # A list made full of nought has its slots cleared by the copying engine (Lowering#emit_list_new).
  # Work RAM is all noughts at power-on, so the list is made full of seven first, and made again
  # full of nought; the list declared after it keeps its nines, so the clear stops at the last slot.
  def test_a_list_made_full_of_nought_again_is_all_noughts_and_its_neighbour_is_left_alone
    %i[byte half word].each do |width|
      program = Build.program(
        Build.list_new(:cleared, 5, width: width, full_of: 7),
        Build.list_new(:beside, 3, width: width, full_of: 9),
        Build.list_new(:cleared, 5, width: width, full_of: 0),
        Build.halt,
        console: :snes
      )
      run = SNES::CheckedRun.new.run(program, frames: 1)

      assert_equal [0, 0, 0, 0, 0], run.list(:cleared), "a list of #{width}s"
      assert_equal [9, 9, 9], run.list(:beside), "a list of #{width}s"
    end
  end

  # Only a hand-built program fills a list it has shifted: the builder refuses one.
  def test_a_fill_that_comes_round_the_ring_agrees_with_the_interpreter
    %i[byte half word].each do |width|
      program = Build.program(
        Build.list_new(:ring, 5, width: width, full_of: 1),
        Build.list_drop(:ring, from: :front),
        Build.list_drop(:ring, from: :front),
        Build.list_drop(:ring, from: :front),
        Build.list_push(:ring, Build.int(7)),
        Build.list_push(:ring, Build.int(8)),
        Build.list_fill(:ring, from: Build.int(1), count: Build.int(3), value: Build.int(-9)),
        Build.halt,
        console: :snes
      )
      run = SNES::CheckedRun.new.run(program, frames: 1)

      assert_equal [1, -9, -9, -9], run.list(:ring), "a list of #{width}s"
    end
  end
end
