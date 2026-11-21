# frozen_string_literal: true

require "test_helper"

# A LIST'S ITEMS WRITTEN INTO A LIST OF BYTES IN ONE STEP (IR list_pack), lowest byte first, from a
# slot the game works out: what a save's snapshot is made of. The cases are the ones a block copy
# can get wrong where a byte at a time could not: slots of each width, a start on an odd slot, a
# list whose oldest item is not in its first slot (it is a ring), a list with nothing in it, and
# the slots on either side of the run, which keep what they held.
#
# Included by the Advance's cartridge test too (test_gba_list_pack.rb), whose lowering copies the
# run as a block.
module ListPackingPrograms
  include VBlank::IR::Build

  ITEMS = Ractor.make_shareable({ byte: [1, 200, -3], half: [1, 40_000, -300], word: [1, -2, 70_000] })
  SLOTS = 14

  # The cases: a name, and the width, the items, the slot the run starts on and whether the list
  # has come round its ring.
  CASES = Ractor.make_shareable((ITEMS.map { |width, items| [width, [width, items, 2, false]] } +
           [[:odd_start, [:word, ITEMS[:word], 1, false]], [:ring, [:half, ITEMS[:half], 3, true]],
            [:empty, [:word, [], 0, false]]]).to_h)

  # SLOTS slots of -1 in a byte list, and +items+ in a list of +width+ written into it from slot
  # +at+. With +ring+, the list's items come round its slots first: two in and out of the front,
  # so its oldest is in its third slot and its newest have come round to the first.
  private def packed(width, items, at, ring)
    lead = ring ? [list_push(:kept, 9), list_push(:kept, 9), list_drop(:kept, from: :front), list_drop(:kept, from: :front)] : []
    program(set(:count, 0), set(:start, at), list_new(:bytes, SLOTS, width: :byte, full_of: -1), list_new(:kept, 3, width: width),
            *lead, *items.map { |item| list_push(:kept, item) },
            list_pack(:kept, into: :bytes, at: var_ref(:start), width: width, index: :count), loop_(wait_vblank))
  end

  # What the bytes list holds: -1 where the run did not reach, and each item's bytes lowest first
  # from +at+, each read back as a byte list reads it.
  private def expected(width, items, at, _ring)
    size = VBlank::IR::ListPacking::WIDTH_BYTES.fetch(width)
    bytes = items.flat_map { |item| Array.new(size) { |b| (item >> (8 * b)) & 0xFF } }.map { |byte| byte > 127 ? byte - 256 : byte }
    Array.new(SLOTS) { |slot| slot >= at && slot < at + bytes.length ? bytes[slot - at] : -1 }
  end
end

class TestListPacking < Minitest::Test
  include ListPackingPrograms

  def test_each_case_is_written_lowest_byte_first_where_it_starts
    CASES.each do |name, (width, items, at, ring)|
      run = game_player.run(packed(width, items, at, ring), frames: 2)

      assert_equal expected(width, items, at, ring), run.list(:bytes), "the #{name} case"
      assert_equal 0, run[:count], "the #{name} case leaves its count at nought"
    end
  end

  # A RUN REACHING PAST THE LIST IT WRITES INTO is what a list_set of each byte in turn would be:
  # the bytes inside it are written and the game stops at the first slot outside it. Two words from
  # slot 12 of 14 stop at slot 14, not at the run's last byte.
  def test_a_run_past_the_end_stops_the_game_at_the_first_slot_outside
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(packed(:word, [1, 2], 12, false), frames: 2) }

    assert_includes error.message, "index 14 is out of range for list :bytes"
  end
end
