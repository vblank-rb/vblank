# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# THE PICTURE WITHOUT ITS SPRITES, OR THE SPRITES ALONE (`layers:`), and, where two cartridges
# part, which of the console's video memories differ. The cartridges are a small tiled game built
# here: a white box sprite standing on a field of sea tiles. One is built with the box a pixel
# off, one with the sea another colour; each comparison finds or forgives exactly that.
class TestComparisonLayersAndMemories < Minitest::Test
  include VBlank::Testing::PlaysAlike

  private def field(box_x: 40, sea: :blue)
    VBlank.build("FIELD", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => sea) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :water, tiles: :set, map: Array.new(20) { "." * 30 }
      sprite :box, at: [box_x, 60]
      game_loop {}
    end
  end

  private def stand = VBlank.playthrough("stand") { wait frames: 20 }

  def test_a_sprite_a_pixel_off_is_forgiven_by_the_picture_without_sprites
    assert_raises(Minitest::Assertion) { assert_plays_alike field, field(box_x: 41), stand }
    assert_plays_alike field, field(box_x: 41), stand, layers: :backgrounds
  end

  def test_a_background_another_colour_is_forgiven_by_the_sprites_alone
    assert_raises(Minitest::Assertion) { assert_plays_alike field, field(sea: :green), stand }
    assert_plays_alike field, field(sea: :green), stand, layers: :sprites
  end

  def test_the_picture_without_sprites_still_finds_a_background_another_colour
    assert_raises(Minitest::Assertion) { assert_plays_alike field, field(sea: :green), stand, layers: :backgrounds }
  end

  def test_layers_other_than_the_two_are_refused
    error = assert_raises(ArgumentError) { stand.compare(nil, nil, layers: :bg0) }

    assert_match "`layers:`", error.message
    assert_match ":backgrounds", error.message
  end

  # Two backgrounds, the first the console's BG0 and the second its BG1, each filled with one
  # colour. +first+ is the colour of the first.
  private def two_fields(first:, second:)
    VBlank.build("FIELDS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:one, "." => first) { "........\n" * 8 }
      image(:two, "." => second) { "........\n" * 8 }
      tiles :ones, "." => :one
      tiles :twos, "." => :two
      background :front, tiles: :ones, map: Array.new(20) { "." * 30 }
      background :back, tiles: :twos, map: Array.new(20) { "." * 30 }
      game_loop {}
    end
  end

  # A LAYER FOR EACH: a port draws its room on other layers than the original, so each side
  # shows its own. Here the sea is on BG0 of the first cartridge and on BG1 of the second.
  def test_each_cartridge_shows_its_own_layers
    sea_first = two_fields(first: :blue, second: :green)
    sea_second = two_fields(first: :green, second: :blue)

    assert_raises(Minitest::Assertion) { assert_plays_alike sea_first, sea_second, stand, layers: [%i[bg0], %i[bg0]] }
    assert_plays_alike sea_first, sea_second, stand, layers: [%i[bg0], %i[bg1]]
    assert_plays_alike sea_first, sea_second, stand, layers: [{ only: %i[bg0] }, { without: %i[bg0 sprites] }]
  end

  def test_a_layer_for_each_that_is_not_two_is_refused
    error = assert_raises(ArgumentError) { stand.compare(nil, nil, layers: [%i[bg0]]) }

    assert_match "`layers:`", error.message
    assert_match "one for each", error.message
  end

  def test_a_layer_the_console_does_not_have_names_the_side
    error = assert_raises(ArgumentError) do
      stand.compare(field, field, layers: [%i[bg0], %i[bg9]])
    end

    assert_match "second cartridge", error.message
  end

  # WHICH VIDEO MEMORIES DIFFER, each with its first difference: the colours for a sea another
  # colour, the sprite table for a box a pixel off. The memories that agree are not named.
  def test_a_drift_names_the_colours_when_a_colour_differs
    drift = stand.compare(field, field(sea: :green)).drift

    memories = drift.video_differences.map(&:memory)
    assert_includes memories, :colors
    refute_includes memories, :sprite_table
    colors = drift.video_differences.find { |difference| difference.memory == :colors }
    refute_equal colors.first, colors.second
  end

  def test_a_drift_names_the_sprite_table_when_a_sprite_is_a_pixel_off
    drift = stand.compare(field, field(box_x: 41)).drift

    assert_equal [:sprite_table], drift.video_differences.map(&:memory)
  end

  def test_a_failure_and_a_report_name_the_memories_that_differ
    failure = assert_raises(Minitest::Assertion) { assert_plays_alike field, field(box_x: 41), stand }
    assert_match "the sprite table", failure.message

    Dir.mktmpdir do |folder|
      stand.compare(field, field(box_x: 41), reports_in: folder)
      assert_match "the sprite table", File.read(Dir.glob(File.join(folder, "*", "report.txt")).first)
    end
  end
end
