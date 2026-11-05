# frozen_string_literal: true

require "test_helper"

# A LIST PUT IN ORDER BY THE NUMBERS ANOTHER LIST HOLDS (IR list_sort), on the PlayStation, held to the
# interpreter pass for pass (PS1::CheckedRun). The lowering sorts a list whose first item stays in its
# first slot with code written where the sort is, and any other through the runtime, which finds each
# item round the ring of slots; both ways are played here, rising and falling, with level numbers, a
# number below nought, and one that changes every pass so items pass each other.
class TestPS1ListSort < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  B = VBlank::IR::Build

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  # Five places and their numbers, either as plain lists or as lists whose items have gone round the
  # ring (+ring+: an item taken from the front of each first). Each pass one number changes, the list is
  # sorted rising and then falling, and each order is kept in a variable, a digit of five a place.
  private def sorting_game(ring:, key_width: nil)
    sort = ->(descending) { B.list_sort(:ranks, by: :heights, descending: descending) }
    program_of do
      ranks = list :ranks, capacity: 5, width: :byte
      heights = key_width ? list(:heights, capacity: 5, width: key_width) : list(:heights, capacity: 5)
      if ring
        ranks.push 9
        heights.push 99
        ranks.shift
        heights.shift
      end
      [3, 0, 4, 1, 2].each { |place| ranks.push place }
      [7, -2, 7, 30, 0].each { |height| heights.push height }
      t = 0
      rising = 0
      falling = 0
      game_loop do
        t += 1
        heights[1] = ((t * 7) % 40) - 10
        record(sort.call(false))
        rising = (((((ranks[0] * 5) + ranks[1]) * 5) + ranks[2]) * 5 + ranks[3]) * 5 + ranks[4]
        record(sort.call(true))
        falling = (((((ranks[0] * 5) + ranks[1]) * 5) + ranks[2]) * 5 + ranks[3]) * 5 + ranks[4]
      end
    end
  end

  def test_a_list_whose_first_item_stays_first_is_sorted_as_the_interpreter_sorts_it
    PS1::CheckedRun.new.run(sorting_game(ring: false), frames: 12)
  end

  def test_narrow_numbers_are_compared_with_their_sign
    PS1::CheckedRun.new.run(sorting_game(ring: false, key_width: :byte), frames: 12)
  end

  def test_a_list_whose_items_go_round_its_slots_is_sorted_as_the_interpreter_sorts_it
    PS1::CheckedRun.new.run(sorting_game(ring: true), frames: 12)
  end
end
