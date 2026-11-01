# frozen_string_literal: true

require "test_helper"

# A COLOUR WALK, the fade a console's own game does: each channel of each colour is one step from
# the last, so a bright channel starts first, a dim colour stays at the far end for most of the
# walk, and every channel arrives on the same step. A mix would show the dim colours sooner.
class TestColorWalk < Minitest::Test
  # Five-bit channels into a colour, red lowest.
  private def rgb5(red, green, blue) = red | (green << 5) | (blue << 10)

  private def built(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The list a walk names at +step+, as the builder declared it.
  private def walk_lists(own, from:, steps:)
    b = Builder.new
    names = nil
    b.instance_eval do
      colors :city, own
      names = color_walk(:city, from: from, steps: steps)
    end
    names.map { |name| b.send(:declared_colors, name) }
  end

  def test_a_walk_from_black_lifts_each_channel_a_step_at_a_time
    own = [:transparent, rgb5(20, 20, 20)]
    lists = walk_lists(own, from: :black, steps: 31)

    assert_equal 32, lists.length
    assert_equal 0, lists[11][1], "twenty steps from the end, a channel of 20 is still black"
    assert_equal rgb5(3, 3, 3), lists[14][1], "and it has come up by three three steps later"
    assert_equal rgb5(8, 8, 8), lists[19][1]
    assert_equal own[1], lists[31][1], "and the last step is the colour itself"
  end

  def test_a_bright_channel_starts_first_and_all_arrive_together
    lists = walk_lists([:transparent, rgb5(31, 10, 0)], from: :black, steps: 31)

    assert_equal rgb5(5, 0, 0), lists[5][1]
    assert_equal rgb5(25, 4, 0), lists[25][1]
    assert_equal rgb5(30, 9, 0), lists[30][1]
    assert_equal rgb5(31, 10, 0), lists[31][1]
  end

  def test_a_walk_from_white_falls_to_the_colour
    lists = walk_lists([:transparent, rgb5(31, 10, 0)], from: :white, steps: 31)

    assert_equal rgb5(31, 31, 31), lists[0][1]
    assert_equal rgb5(31, 11, 1), lists[30][1]
    assert_equal rgb5(31, 10, 0), lists[31][1]
  end

  def test_fewer_steps_start_nearer
    lists = walk_lists([:transparent, rgb5(20, 20, 20)], from: :black, steps: 4)

    assert_equal [rgb5(16, 16, 16), rgb5(17, 17, 17), rgb5(18, 18, 18), rgb5(19, 19, 19), rgb5(20, 20, 20)],
                 lists.map { |list| list[1] }
  end

  # The background walks while a sprite drawn in the same colour stays as it is.
  def test_a_background_walks_up_while_a_sprite_stays
    seen = game_player
    seen.run(walking_game, frames: 16)

    assert_equal rgb5(10, 10, 10), seen.screen.pixel(4, 4), "the walked background, ten steps of twenty up"
    assert_equal rgb5(20, 20, 20), seen.screen.pixel(4, 62), "the sprite is as drawn"
  end

  private def walking_game
    gray = rgb5(20, 20, 20)
    built do
      screen :tiled
      colors :city, [:transparent, gray]
      colors :sky, [:transparent, gray]
      image(:city_art, colors: :city, width: 8, height: 8, places: Array.new(64, 1))
      image(:sky_art, colors: :sky, width: 8, height: 8, places: Array.new(64, 1))
      tiles :city_tiles, "#" => :city_art
      city = background :city_layer, tiles: :city_tiles, map: Array.new(4) { "#" * 32 }
      sprite :sky_art, at: [0, 60]
      walk = color_walk(:city, from: :black, steps: 20)
      step = 0
      game_loop do
        city.draw_with walk, showing: step
        step += 1 if step < 10
      end
    end
  end

  # A long walk beside a short fade, as a title does: the walk runs while the screen fades out.
  # The walk is lists, so the fade keeps its own length, and each is checked against the
  # interpreter on every frame on the runs that build the game.
  def test_a_walk_and_a_short_fade_run_at_once
    gray = rgb5(20, 20, 20)
    game = built do
      screen :tiled
      colors :city, [:transparent, gray]
      image(:city_art, colors: :city, width: 8, height: 8, places: Array.new(64, 1))
      tiles :city_tiles, "#" => :city_art
      city = background :city_layer, tiles: :city_tiles, map: Array.new(4) { "#" * 32 }
      walk = color_walk(:city, from: :black, steps: 20)
      step = 0
      game_loop do
        city.draw_with walk, showing: step
        step += 1 if step < 20
        fade_out frames: 4 if step == 6
      end
    end
    seen = game_player
    seen.run(game, frames: 30)

    assert_equal 0, seen.screen.pixel(4, 4), "faded out, whatever the walk reached"
  end

  # A list of sprite colours walks by `recolor`, and only sprites drawn with it move.
  def test_a_sprite_list_walks
    gray = rgb5(20, 20, 20)
    game = built do
      screen :tiled
      colors :letters, [:transparent, gray]
      colors :others, [:transparent, gray]
      image(:letter, colors: :letters, width: 8, height: 8, places: Array.new(64, 1))
      image(:other, colors: :others, width: 8, height: 8, places: Array.new(64, 1))
      letter = sprite :letter, at: [8, 8]
      letter.draw_with :letters
      sprite :other, at: [24, 8]
      walk = color_walk(:letters, from: :white, steps: 8)
      step = 0
      game_loop do
        recolor :letters, walk, showing: step
        step += 1 if step < 4
      end
    end
    seen = game_player
    seen.run(game, frames: 12)

    assert_equal shown(rgb5(24, 24, 24)), seen.screen.pixel(10, 10), "four steps of eight on from white"
    assert_equal shown(gray), seen.screen.pixel(26, 10), "the other sprite is as drawn"
  end

  def test_a_colour_a_walk_does_not_know_is_a_friendly_error
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { color_walk(:nothing, from: :black) } }

    assert_match(/:nothing/, error.message)
    assert_match(/`colors :nothing/, error.message)
  end

  def test_a_walk_needs_a_positive_number_of_steps
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        colors :city, %i[transparent red]
        color_walk(:city, from: :black, steps: 0)
      end
    end

    assert_match(/steps:/, error.message)
  end
end
