# frozen_string_literal: true

require "test_helper"

# A LIST PUT IN ORDER ON THE COLOR, for every width its slots and its numbers' slots can be: the
# Color's sort reads an item as wide as its list's slots, finds the item's number as wide as the
# other list's, and compares whole signed numbers, so each pair of widths is a different walk.
# Numbers below nothing and level numbers are in each, since those are where a sort goes wrong.
class TestGBCListSort < Minitest::Test
  B = VBlank::IR::Build

  private def sorted(items, item_width, keys, key_width, descending: false)
    prog = B.program(
      B.screen(:bitmap),
      B.list_new(:items, [items.length, 1].max, width: item_width),
      *items.map { |item| B.list_push(:items, item) },
      B.list_new(:keys, keys.length, width: key_width),
      *keys.map { |key| B.list_push(:keys, key) },
      B.list_sort(:items, by: :keys, descending: descending),
      B.loop_(B.wait_vblank)
    )
    game_player.run(prog, frames: 2).list(:items)
  end

  def test_places_in_bytes_by_whole_numbers
    keys = [7, -2, 7, 300_000, -70_000, 0]

    assert_equal [4, 1, 5, 0, 2, 3], sorted([5, 3, 0, 4, 1, 2], :byte, keys, :word)
    assert_equal [3, 0, 2, 5, 1, 4], sorted([4, 1, 5, 0, 2, 3], :byte, keys, :word, descending: true)
  end

  def test_places_in_halves_by_bytes
    assert_equal [2, 0, 3, 1], sorted([3, 2, 1, 0], :half, [-1, 100, -1, 5], :byte)
  end

  def test_places_in_whole_numbers_by_halves
    assert_equal [1, 2, 0], sorted([2, 0, 1], :word, [-300, 300, 0], :half, descending: true)
  end

  def test_one_item_and_none_stay_as_they_are
    assert_equal [0], sorted([0], :byte, [5], :word)
    assert_equal [], sorted([], :byte, [5], :word)
  end
end
