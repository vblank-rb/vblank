# frozen_string_literal: true

require "test_helper"

# A map of the pack that carries its own size (`pack[:hall_map].as_map(across: 30)`): the slot, and
# how many cells a row of it holds, so a background is given the map alone.
class TestPackMap < Minitest::Test
  private def map_slot(count: 12) = VBlank::DSL::PackSlot.new(layout: VBlank::Original::Slot.map_cells(:hall_map, count: count))

  def test_a_map_knows_its_width_and_height
    map = map_slot.as_map(across: 4)

    assert_equal [4, 3], [map.across, map.down]
    assert_equal map_slot, map.slot
  end

  def test_a_height_given_that_matches_is_taken
    assert_equal 3, map_slot.as_map(across: 4, down: 3).down
  end

  def test_a_width_the_cells_do_not_divide_by_is_a_friendly_error
    error = assert_raises(ArgumentError) { map_slot.as_map(across: 5) }

    assert_match(/across:/, error.message)
    assert_match(/12/, error.message)
  end

  def test_a_height_that_does_not_match_is_a_friendly_error
    error = assert_raises(ArgumentError) { map_slot.as_map(across: 4, down: 4) }

    assert_match(/down:/, error.message)
  end

  def test_a_map_of_a_slot_of_tiles_is_a_friendly_error
    tiles = VBlank::DSL::PackSlot.new(layout: VBlank::Original::Slot.tiles(:video, count: 4))
    error = assert_raises(ArgumentError) { tiles.as_map(across: 2) }

    assert_match(/as_map/, error.message)
    assert_match(/tiles/, error.message)
  end
end
