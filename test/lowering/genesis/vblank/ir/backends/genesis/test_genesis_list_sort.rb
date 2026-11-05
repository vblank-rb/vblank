# frozen_string_literal: true

require "test_helper"

# A LIST PUT IN ORDER BY THE NUMBERS ANOTHER LIST HOLDS (IR list_sort), as the Genesis writes it in
# place, does what the interpreter does on every pass (Genesis::CheckedRun): the numbers change every
# pass, with level ones and ones below nought, so a sort that is not stable, or compares without the
# sign, puts the places the wrong way round. The list is walked by pointer when its first item is in
# its first slot, and by index when the game has taken from its front, so it goes round its slots.
class TestGenesisListSort < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis
  Build = VBlank::IR::Build

  # Five places in :order, sorted every pass by :heights, which +width+ keeps; with +ring+, the
  # list's first item has been taken and put back at the end, so it starts in its second slot.
  private def sorting_game(width:, descending:, ring: false)
    builder = Builder.new
    builder.instance_eval do
      list :order, capacity: 5, width: :byte
      width == :word ? list(:heights, capacity: 5, full_of: 0) : list(:heights, capacity: 5, width: width, full_of: 0)
      (0..4).each { |place| record(Build.list_push(:order, place)) }
      if ring
        record(Build.list_drop(:order, from: :front))
        record(Build.list_push(:order, 0))
      end
      t = var :t, 0
      game_loop do
        t += 1
        5.times { |i| record(Build.list_set(:heights, i, Build.binop(:-, VBlank::DSL::Value.node_for((t * (i + 3)) & 7), 3))) }
        record(Build.list_sort(:order, by: :heights, descending: descending))
      end
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  private def assert_sorts_as_the_interpreter(program)
    run = Genesis::CheckedRun.new.run(program, frames: 12)

    assert_equal [0, 1, 2, 3, 4], run.list(:order).sort
  end

  def test_a_list_sorted_rising_agrees_with_the_interpreter
    assert_sorts_as_the_interpreter(sorting_game(width: :word, descending: false))
  end

  def test_a_list_sorted_falling_by_narrow_numbers_agrees_with_the_interpreter
    assert_sorts_as_the_interpreter(sorting_game(width: :byte, descending: true))
    assert_sorts_as_the_interpreter(sorting_game(width: :half, descending: false))
  end

  def test_a_list_going_round_its_slots_is_sorted_as_the_interpreter_sorts_it
    assert_sorts_as_the_interpreter(sorting_game(width: :word, descending: false, ring: true))
    assert_sorts_as_the_interpreter(sorting_game(width: :byte, descending: true, ring: true))
  end
end
