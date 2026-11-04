# frozen_string_literal: true

require "test_helper"

# `border` (Builder::Images#border): the picture round a game's screen where a build shows that
# screen in the middle of a bigger one, a game laid out for the Game Boy Color on the Advance
# (`variants: { gba: :color_screen }`). What the Advance's cartridge shows is read in the emulator
# in test/lowering/gba/vblank/ir/backends/gba/test_border_sprites.rb.
class TestBorder < Minitest::Test
  # The game +block+ is the body of, for the Color and for the Advance with the Color's screen.
  private def game(&block) = VBlank.game("BORDER", consoles: %i[gbc gba], variants: { gba: :color_screen }, &block)

  def test_a_border_rides_with_the_advances_build_and_not_the_colors
    made = game { border("#" => :blue, "." => :cyan) { "#.\n" } }

    assert_equal [2, 1], made.program(console: :gba).border_size
    assert_nil made.program(console: :gbc).border, "the Color shows its screen whole and keeps no border"
  end

  def test_a_game_that_gives_no_border_gets_the_builds_own
    assert_nil game { var :x, 1 }.program(console: :gba).border
  end

  def test_a_border_with_see_through_pixels_is_refused
    made = game { border("#" => :blue, "." => :transparent) { "#.\n" } }

    error = assert_raises(ArgumentError) { made.program(console: :gba) }
    assert_match(/see-through/, error.message)
  end

  def test_a_border_of_more_than_fifteen_colors_is_refused
    many = (0...16).map { |n| VBlank::Graphics::Color.rgb(n, 0, 0) }
    made = game { border(width: 16, height: 1, data: many) }

    error = assert_raises(ArgumentError) { made.program(console: :gba) }
    assert_match(/16 colors/, error.message)
  end

  def test_a_border_that_does_not_repeat_across_the_screen_is_refused
    made = game { border("#" => :blue) { "###\n" * 7 } }

    error = assert_raises(ArgumentError) { made.program(console: :gba) }
    assert_match(/240×160/, error.message)
  end

  def test_a_border_said_twice_is_refused
    made = game do
      border("#" => :blue) { "#\n" }
      border("#" => :cyan) { "#\n" }
    end

    error = assert_raises(ArgumentError) { made.program(console: :gba) }
    assert_match(/twice/, error.message)
  end

  def test_a_border_is_no_picture_of_the_games
    made = game do
      border("#" => :blue) { "#\n" }
      var :x, 1
    end

    refute(made.program(console: :gba).walk.any? { |node| node.kind == :bitmap })
  end
end
