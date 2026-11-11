# frozen_string_literal: true

require "test_helper"

# A SPRITE OVER THE PICTURE DRAWN WITH ANOTHER LIST OF COLOURS ON A PC, in DOSBox, held to the interpreter on
# every pass (DOS::CheckedRun). The card has one palette, so each picture is kept once for each set of colours
# it can be drawn in and placing the sprite picks one: what `draw_with` and `recolor` do is in
# test/all/vblank/builder/test_recolor.rb, on a screen drawn from tiles, which DOS does not make yet.
class TestDOSSpriteColors < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  OWN = %i[transparent red green].freeze
  SLOT = %i[transparent blue white].freeze
  WARM = %i[transparent yellow orange].freeze
  COLD = %i[transparent gray magenta].freeze

  # A ship of 8 by 8, its left half the first colour of its list and its right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # The ship's left half and its right, with the ship at (40, 40).
  HALVES = [[41, 41], [45, 41]].freeze

  private def checked(frames:, &game)
    made = VBlank.game("DOSGAME", consoles: %i[dos]) do
      screen :bitmap
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :slot, SLOT
      colors :warm, WARM
      colors :cold, COLD
      clear_screen :cyan
      instance_eval(&game)
    end
    DOS::CheckedRun.new.run(made.program(console: :dos), frames: frames)
  end

  private def colors(*names) = names.map { |name| VBlank::Graphics::Color.resolve(name) }
  private def halves(run) = HALVES.map { |x, y| run.screen.pixel(x, y) }

  def test_a_sprite_told_to_draw_with_a_list_shows_its_colours_by_place
    run = checked(frames: 4) do
      ship = sprite :ship, at: [40, 40], over_picture: true
      ship.draw_with :warm
      game_loop {}
    end

    assert_equal colors(:yellow, :orange), halves(run)
    assert_equal colors(:cyan), [run.screen.pixel(48, 41)], "the picture beside the sprite is as painted"
  end

  # One of several by a number the game works out, and a number past the end is the sprite's own.
  def test_a_number_picks_which_list_and_one_outside_them_is_its_own
    seen = [2, 4, 6, 9].map do |frames|
      run = checked(frames: frames) do
        ship = sprite :ship, at: [40, 40], over_picture: true
        passes = var :passes, 0
        game_loop do
          ship.draw_with %i[warm cold slot], showing: passes >> 1
          ship.x += 0
          passes += 1
        end
      end
      halves(run)
    end

    assert_equal [colors(:yellow, :orange), colors(:gray, :magenta), colors(:blue, :white), colors(:red, :green)], seen
  end

  # A list the game changes dresses every sprite drawn with it, and `:own` is what it was declared with.
  def test_a_list_told_to_hold_other_colours_changes_the_sprites_drawn_with_it
    seen = [2, 5, 8, 11].map do |frames|
      run = checked(frames: frames) do
        ship = sprite :ship, at: [40, 40], over_picture: true
        other = sprite :ship, at: [100, 40], over_picture: true
        ship.draw_with :slot
        other.draw_with :slot
        passes = var :passes, 0
        game_loop do
          recolor :slot, %i[warm cold], showing: passes / 3 - 1
          other.x += 1
          passes += 1
        end
      end
      halves(run)
    end

    assert_equal [colors(:blue, :white), colors(:yellow, :orange), colors(:gray, :magenta), colors(:blue, :white)], seen
  end
end
