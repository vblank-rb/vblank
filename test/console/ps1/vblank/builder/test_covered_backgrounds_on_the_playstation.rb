# frozen_string_literal: true

require "test_helper"

# Three backgrounds at once, the middle one drawing every pixel, on every run that plays games as the
# PlayStation. Its build leaves out what such a background hides (Runtime::Tiles' rt_tiles_draw): the
# backdrop and the background behind. The picture must be the interpreter's all the same, as the middle
# one scrolls and the one in front shows it through its gaps. Not in test/all/: the Color shows one
# background at a time, and these games show two and three.
class TestCoveredBackgroundsOnThePlayStation < Minitest::Test
  def test_a_background_that_draws_every_pixel_hides_the_ones_behind
    screen = game_player.run(covered_program, frames: 4).screen
    blue, green, white = %i[blue green white].map { |name| Color.resolve(name) }

    assert_equal white, screen.pixel(8, 8), "the front background's dot"
    assert_includes [blue, green], screen.pixel(9, 8), "the middle background, through the front's gap"
    refute_equal screen.pixel(9, 8), screen.pixel(10, 8), "the middle background's checks"
  end

  # A scene's own background that draws every pixel hides the one every screen shows; once a scene without
  # it takes over, the one behind shows again.
  def test_the_background_behind_shows_again_once_it_is_taken_down
    hidden = game_player.run(scene_program, frames: 2).screen.pixel(9, 8)
    shown = game_player.run(scene_program, frames: 6).screen.pixel(9, 8)

    refute_equal Color.resolve(:red), hidden, "the scene's own background in front"
    assert_equal Color.resolve(:red), shown, "the one behind, once the scene's own is taken down"
  end

  private def scene_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:red_tile, "#" => :red) { "########\n" * 8 }
      image(:checks, "#" => :blue, "." => :green) { "#.#.#.#.\n.#.#.#.#\n" * 4 }
      tiles :back_set, "#" => :red_tile
      tiles :middle_set, "#" => :checks
      background :back, tiles: :back_set, map: Array.new(32) { "#" * 32 }
      scene(:covered) { background :middle, tiles: :middle_set, map: Array.new(32) { "#" * 32 } }
      scene(:bare) { nil }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick > 3
        case_var(:state) do
          when_val 0, :covered
          when_val 1, :bare
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def covered_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:red_tile, "#" => :red) { "########\n" * 8 }
      image(:checks, "#" => :blue, "." => :green) { "#.#.#.#.\n.#.#.#.#\n" * 4 }
      image(:dots, "#" => :white, "." => :transparent) { "#.......\n" + ("........\n" * 7) }
      tiles :back_set, "#" => :red_tile
      tiles :middle_set, "#" => :checks
      tiles :front_set, "#" => :dots
      background :back, tiles: :back_set, map: Array.new(32) { "#" * 32 }
      middle = background :middle, tiles: :middle_set, map: Array.new(32) { "#" * 32 }
      background :front, tiles: :front_set, map: Array.new(32) { "#" * 32 }
      game_loop { middle.scroll_by 1, 0 }
    end
    b.finalize_program
    b.program
  end
end
