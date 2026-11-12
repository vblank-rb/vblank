# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "sprite_box_fields"

# THE PICTURE WITH EVERY SPRITE'S BOX LEFT OUT (`ignoring_sprites: true`): a port whose scenery is
# right is held to its original's scenery everywhere but under the characters, which the original
# shows on top anyway. The boxes are read from each console's own sprite table, on the frame
# compared and the frame before, on both cartridges.
#
# The cartridges are SpriteBoxFields' sea with its hollow box. The cell of rock at [5, 7], pixels 40
# to 47 across and 56 to 63 down, is under the box on every frame and shows through it; at [20, 15]
# no sprite comes near it.
class TestComparisonIgnoringSprites < Minitest::Test
  include VBlank::Testing::PlaysAlike
  include SpriteBoxFields

  FAR_FROM_THE_BOX = [20, 15].freeze

  private def field(odd_cell: nil) = sea_with_box(console: :gba, columns: 30, rows: 20, odd_cell: odd_cell)
  private def bare_field = bare_sea(console: :gba, columns: 30, rows: 20)
  private def stand = VBlank.playthrough("stand") { wait frames: 30 }

  def test_scenery_that_differs_only_under_a_moving_sprite_plays_alike
    assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, ignoring_sprites: true
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
    assert_equal [160, 120], drift.picture_difference[:box].first(2)
  end

  # A sprite on one cartridge only is left out too: the original shows a character where the port
  # draws none yet.
  def test_a_sprite_on_one_cartridge_only_is_left_out
    assert_raises(Minitest::Assertion) { assert_plays_alike bare_field, field, stand }
    assert_plays_alike bare_field, field, stand, ignoring_sprites: true
  end

  # A BOX THAT JUMPS ACROSS THE SCREEN ON EVERY FRAME, on one cartridge only, is left out wherever
  # the picture shows it. (On the Advance the table read after a frame is the one its picture was
  # drawn from, so this holds with the frame's own boxes; the frame before's are for a console or a
  # game that writes its table while the frame is drawn.)
  def test_a_sprite_that_jumps_every_frame_is_left_out_where_it_was_drawn
    jumper = VBlank.build("JUMPER", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :water, tiles: :set, map: Array.new(20) { "." * 30 }
      box = sprite :box, at: [32, 52]
      game_loop { box.x = 152 - box.x }
    end

    assert_plays_alike bare_field, jumper, stand, ignoring_sprites: true
  end

  # Lined up by passes, the frame before is each cartridge's own.
  def test_two_lined_up_by_passes_leave_out_the_sprites_too
    assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, ignoring_sprites: true, by_passes: true
  end

  # The port's call shape: the frames before the scenery is ready are left out as well.
  def test_the_setting_goes_with_frames_left_out
    assert_plays_alike field, field(odd_cell: UNDER_THE_BOX), stand, ignoring_frames: [1..5], ignoring_sprites: true
  end

  def test_a_report_says_the_sprites_were_left_out
    Dir.mktmpdir do |folder|
      stand.compare(field, field(odd_cell: FAR_FROM_THE_BOX), ignoring_sprites: true, reports_in: folder)

      assert_match "sprite", File.read(Dir.glob(File.join(folder, "*", "report.txt")).first)
    end
  end

  def test_a_setting_that_is_not_true_or_two_sizes_is_refused
    error = assert_raises(ArgumentError) { stand.compare(nil, nil, ignoring_sprites: :yes) }

    assert_match "`ignoring_sprites:`", error.message
    assert_match "true", error.message
  end

  def test_the_same_script_refuses_the_setting
    error = assert_raises(ArgumentError) do
      VBlank.playthrough("stand") do
        wait frames: 5
        moment :still
      end.compare(nil, nil, same: :script, ignoring_sprites: true)
    end

    assert_match "`ignoring_sprites:`", error.message
  end

  # The strict rule for torn frames does not take each frame's own boxes yet.
  def test_the_strict_rule_for_torn_frames_is_refused_beside_it
    error = assert_raises(ArgumentError) { stand.compare(nil, nil, forgiving_torn_frames_of: :first, ignoring_sprites: true) }

    assert_match "`forgiving_torn_frames_of:`", error.message
    assert_match "`ignoring_sprites:`", error.message
  end
end
