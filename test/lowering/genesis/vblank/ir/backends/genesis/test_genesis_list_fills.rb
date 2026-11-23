# frozen_string_literal: true

require "test_helper"

# A list set to one value (Runtime::Lists rt_list_fill, which writes the slots straight through), held
# to the interpreter by the checked run: a list declared full of a value, a whole list filled and a run
# of it, for each width of slot; a list whose first item has moved round its ring, so the run of slots
# it fills comes round to the first slot; and a run that ends or starts outside the list.
class TestGenesisListFills < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis
  Build = VBlank::IR::Build

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def test_lists_of_each_width_filled_whole_and_in_part_agree_with_the_interpreter
    run = Genesis::CheckedRun.new.run(program_of do
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
        console: :genesis
      )
      run = Genesis::CheckedRun.new.run(program, frames: 1)

      assert_equal [1, -9, -9, -9], run.list(:ring), "a list of #{width}s"
    end
  end

  # Both ends are checked before a slot is written: a run past the end stops the game naming its last
  # index, and one from before the start names its first, as the interpreter does.
  def test_a_run_outside_the_list_stops_the_game_in_the_interpreters_words
    { 2 => /index 6 is out of range for list :short/, -1 => /index -1 is out of range for list :short/ }.each do |from, words|
      error = assert_raises(VBlank::IR::ProgramError) do
        Genesis::CheckedRun.new.run(program_of do
          short = list :short, capacity: 6, full_of: 1
          at = var :at, from
          game_loop { short.fill 5, from: at, count: 5 }
        end, frames: 3)
      end

      assert_match words, error.message
    end
  end
end
