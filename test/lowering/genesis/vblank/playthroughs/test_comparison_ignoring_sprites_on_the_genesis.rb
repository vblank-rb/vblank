# frozen_string_literal: true

require "test_helper"
require "sprite_box_fields"

# EVERY SPRITE'S BOX LEFT OUT (`ignoring_sprites: true`) on the Genesis, where it is the only way to
# hold scenery while the characters are not made: Genesis Plus GX draws every layer together, so
# `layers: :backgrounds` is refused. The boxes are read from the console's own sprite table, the
# entries followed by their links.
#
# The cartridges are SpriteBoxFields' sea with its hollow box. The cell of rock at [5, 7] is under
# the box on every frame, and at [30, 20] no sprite comes near it.
class TestComparisonIgnoringSpritesOnTheGenesis < Minitest::Test
  include VBlank::Testing::PlaysAlike
  include SpriteBoxFields

  FAR_FROM_THE_BOX = [30, 20].freeze

  # The frames the cartridge takes to start and show the box: the field shows on frame 10, a frame
  # before the game's first pass places the box, so the rock is bare there.
  START_UP = 11

  private def field(odd_cell: nil) = sea_with_box(console: :genesis, columns: 40, rows: 32, odd_cell: odd_cell)
  private def bare_field = bare_sea(console: :genesis, columns: 40, rows: 32)

  # Long enough to pass the start-up, which shows nothing for its first frames.
  private def stand = VBlank.playthrough("stand") { wait frames: 40 }

  # The start-up is left out, as a port leaves out what comes before its scenery.
  def test_scenery_that_differs_only_under_a_moving_sprite_plays_alike
    assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, ignoring_frames: [1..START_UP], ignoring_sprites: true
  end

  def test_scenery_that_differs_under_a_sprite_drifts_without_the_setting
    assert_raises(Minitest::Assertion) { assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand }
  end

  def test_scenery_that_differs_away_from_every_sprite_drifts
    drift = stand.compare(field, field(odd_cell: FAR_FROM_THE_BOX), ignoring_sprites: true).drift

    refute_nil drift
    assert_equal [240, 160], drift.picture_difference[:box].first(2)
  end

  # The port's call shape: the original's characters are there, the port's are not, and the frames
  # before the scenery is ready are left out.
  def test_sprites_on_one_cartridge_only_are_left_out
    assert_raises(Minitest::Assertion) { assert_plays_alike bare_field, field, stand }
    assert_plays_alike bare_field, field, stand, ignoring_frames: [1..START_UP], ignoring_sprites: true
  end
end
