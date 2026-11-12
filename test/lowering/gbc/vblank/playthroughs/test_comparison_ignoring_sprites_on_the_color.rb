# frozen_string_literal: true

require "test_helper"
require "sprite_box_fields"

# EVERY SPRITE'S BOX LEFT OUT (`ignoring_sprites: true`) on the Game Boy Color, read from the
# console's own table of forty eight-pixel pieces: each 8 wide, and 8 or 16 tall as the register LCDC
# sets.
#
# The cartridges are SpriteBoxFields' sea with its hollow box. The cell of rock at [5, 7] is under
# the box on every frame, and at [15, 12] no sprite comes near it.
class TestComparisonIgnoringSpritesOnTheColor < Minitest::Test
  include VBlank::Testing::PlaysAlike
  include SpriteBoxFields

  FAR_FROM_THE_BOX = [15, 12].freeze

  # The frames the cartridge takes to start and show the box: the field shows on frame 5, a frame
  # before the game's first pass places the box, so the rock is bare there.
  START_UP = 6

  private def field(odd_cell: nil) = sea_with_box(console: :gbc, columns: 32, rows: 32, odd_cell: odd_cell)
  private def stand = VBlank.playthrough("stand") { wait frames: 30 }

  # The start-up is left out, as a port leaves out what comes before its scenery.
  def test_scenery_that_differs_only_under_a_moving_sprite_plays_alike
    assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, ignoring_frames: [1..START_UP], ignoring_sprites: true
  end

  def test_scenery_that_differs_under_a_sprite_drifts_without_the_setting
    assert_raises(Minitest::Assertion) { assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand }
    assert_raises(Minitest::Assertion) do
      assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, layers: :backgrounds
    end
  end

  def test_scenery_that_differs_away_from_every_sprite_drifts
    drift = stand.compare(field, field(odd_cell: FAR_FROM_THE_BOX), ignoring_sprites: true).drift

    refute_nil drift
    assert_equal [120, 96], drift.picture_difference[:box].first(2)
  end
end
