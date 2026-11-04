# frozen_string_literal: true

require "test_helper"

# A list keeps its items in a ring of slots: taking one from the front moves where the first item is,
# and the next push goes round to the slot that freed. A narrow slot keeps the low bits and reads back
# with its sign (200 in a byte reads -56). A run of a table copied into a list lands in that list's own
# slots, held inside the table, and leaves the list declared before it alone.
class TestListRing < Minitest::Test
  private def played(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    game_player.run(builder.program, frames: 2)
  end

  def test_a_push_after_a_shift_goes_round_the_ring_and_a_byte_keeps_its_sign
    run = played do
      trail = list :trail, capacity: 3, width: :byte
      first = 0
      last = 0
      trail.push 100
      trail.push 200
      trail.shift
      trail.push 50
      trail.push 60
      game_loop do
        first = trail[0]
        last = trail[trail.length - 1]
      end
    end

    assert_equal [-56, 50, 60], run.list(:trail)
    assert_equal [-56, 60], [run[:first], run[:last]]
  end

  def test_a_table_copied_into_a_list_is_held_inside_the_table_and_leaves_the_list_before_it_alone
    run = played do
      lut = table :lut, [10, 20, 30, 40, 50], width: :byte, signed: false
      first = list :first, capacity: 3
      narrow = list :narrow, capacity: 4, width: :byte
      at = 0
      got = 0
      first.push 5
      game_loop do
        at = (at * 0) + 3
        narrow.copy_from lut, at: at, count: 3
        got = narrow[2] + lut[1]
      end
    end

    assert_equal [5], run.list(:first)
    assert_equal [30, 40, 50], run.list(:narrow)
    assert_equal 70, run[:got]
  end
end
