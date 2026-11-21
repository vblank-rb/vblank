# frozen_string_literal: true

require "test_helper"
require "differential"
require "status_bar_games"

# A status bar is a strip of tiles fixed to the screen, from a row the game says down to the
# bottom, over a field that scrolls and changes under it: the score along the bottom of a
# pinball table, the lives and keys along the bottom of a dungeon. It does not scroll with the
# field, it has its own tiles and colours, and the game can slide it down out of view and back
# (test/all/vblank/dsl/test_status_bar.rb).
#
# Every test lays the screen out from the console's own size, so it plays on the Advance and on
# the Color alike.
class TestStatusBar < Minitest::Test
  include Differential
  include StatusBarGames

  def test_the_bar_covers_the_bottom_rows_and_stays_while_the_field_scrolls_under_it
    prog = bar_game
    bar_row = screen_height - (BAR_HEIGHT / 2)

    [6, 9].each do |frames|
      assert_equal GREEN, picture(prog, frames).pixel(8, bar_row), "the bar after #{frames} passes"
    end
    above = (2..9).map { |frames| picture(prog, frames).pixel(8, 28) }
    assert_includes above, BLUE, "the field above the bar scrolls past its blue rows"
    assert_includes above, RED
    assert_backends_agree(prog, frames: [3, 9], name: "BAR")
  end

  # Past the last row of the bar's map, down to the bottom of the screen, is still the bar: the
  # field is not drawn there, and the backdrop shows.
  def test_rows_past_the_bars_map_show_the_backdrop_not_the_field
    prog = bar_game(from_bottom: 40)
    shown = picture(prog, 6)

    assert_equal GREEN, shown.pixel(8, screen_height - 36), "the bar's own rows"
    assert_equal BLACK, shown.pixel(8, screen_height - 8), "past its map"
    assert_backends_agree(prog, frames: 6, name: "BARPAST")
  end

  # A sprite is drawn over the bar, and the bar's see-through pixels show the backdrop rather
  # than the field under them.
  def test_a_sprite_shows_over_the_bar_and_its_see_through_pixels_show_the_backdrop
    prog = program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:edge_art, "#" => :green, "." => :transparent) { (["####...."] * 8).join("\n") }
      image(:ball, "#" => :white) { (["########"] * 8).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :edge_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      sprite :ball, at: [40, screen_height - 12]
      game_loop {}
    end
    shown = picture(prog, 4)
    row = screen_height - 4

    assert_equal GREEN, shown.pixel(2, row)
    assert_equal BLACK, shown.pixel(6, row), "a see-through pixel of the bar"
    assert_equal Color.resolve(:white), shown.pixel(44, row - 4), "the sprite"
    assert_equal RED, shown.pixel(6, row - 20), "the field above the bar"
    assert_backends_agree(prog, frames: 4, name: "BARSPR")
  end

  # A bar takes no layer in a game that names its layers: it is in front of the backgrounds and
  # behind the sprites whatever the stack says.
  def test_a_bar_in_a_game_with_layers_is_in_front_of_the_backgrounds_and_behind_the_sprites
    prog = program do
      screen :tiled
      layers :world, :front
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      image(:ball, "#" => :white) { (["########"] * 8).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      layer(:front) { sprite :ball, at: [40, screen_height - 12] }
      layer(:world) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      game_loop {}
    end
    shown = picture(prog, 4)

    assert_equal GREEN, shown.pixel(8, screen_height - 4)
    assert_equal Color.resolve(:white), shown.pixel(44, screen_height - 8)
    assert_backends_agree(prog, frames: 4, name: "BARLAYER")
  end

  # The bars the console cannot keep where they are put are refused where they are written.
  def test_a_bar_the_console_cannot_keep_is_a_friendly_error
    {
      "needs a `screen :tiled`" => -> { screen :bitmap },
      "takes no layer" => -> { layers(:ui) && layer(:ui) { status_bar :score, tiles: :bar_tiles, map: ["#"], top: 0 } },
      "holds 32 by 32 cells" => -> { status_bar :score, tiles: :bar_tiles, map: ["#" * 33], top: 0 },
      "must be a whole number" => -> { status_bar :score, tiles: :bar_tiles, map: ["#"], top: var(:row, 3) }
    }.each do |phrase, misuse|
      error = assert_raises(ArgumentError, phrase) do
        program do
          screen :tiled
          image(:green_art, "#" => :green) { SOLID_TILE }
          tiles :bar_tiles, "#" => :green_art
          instance_exec(&misuse)
          status_bar :score, tiles: :bar_tiles, map: ["#"], top: 0
        end
      end
      assert_includes error.message, phrase
    end
  end

  # A game that runs +bar_scene+ from its first pass, a scene with nothing of its own from pass
  # 5, and +bar_scene+ again from pass 8, over a red field every screen shows.
  private def scene_leaves_and_comes_back(&bar_scene)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      image(:blue_art, "#" => :blue) { SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art, "o" => :blue_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      state = var :state, 0
      tick = var :tick, 0
      scene(:play) { instance_exec(tick, &bar_scene) }
      scene(:pause) {}
      game_loop do
        tick += 1
        state = 1 if tick == 5
        state = 0 if tick == 8
        case_var(:state) do
          when_val 0, :play
          when_val 1, :pause
        end
      end
    end
  end

  # A bar every screen shows stays at its row on the frame a scene takes over with a field of its
  # own: the interpreter once drew it from the screen's corner as it put the scenes' scenery back.
  def test_a_bar_every_screen_shows_stays_put_as_a_scene_takes_over
    prog = program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:blue_art, "#" => :blue) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      tiles :red_tiles, "#" => :red_art
      tiles :blue_tiles, "#" => :blue_art
      tiles :bar_tiles, "#" => :green_art
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :red_tiles, map: Array.new(32) { "#" * 32 } }
      scene(:two) { background :two, tiles: :blue_tiles, map: Array.new(32) { "#" * 32 } }
      game_loop do
        tick += 1
        state = 1 if tick == 4
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal BLUE, picture(prog, 4).pixel(8, 8), "the second scene's field, at the top"
    assert_equal GREEN, picture(prog, 4).pixel(8, screen_height - 4), "and the bar, at the bottom"
    assert_backends_agree(prog, frames: [3, 4, 5], name: "BARTAKE")
  end

  # A bar put up by a routine the loop calls (the way a game's routine that draws the screen does)
  # shows from the first frame the field does, before the loop has run its line. The interpreter
  # builds the picture from the scenery every screen shows, the bar at its declared top among it,
  # as soon as a background goes up (IR::SceneHandover#bar_shown_early). Frame 1 is shown before the
  # loop has run.
  def test_a_bar_first_put_up_in_the_game_loop_shows_on_the_first_frame
    prog = routine_bar_game do
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      game_loop { call :put_up_bar }
    end

    assert_equal GREEN, picture(prog, 1).pixel(8, screen_height - 4), "the bar, on the first frame"
    assert_equal RED, picture(prog, 1).pixel(8, 8), "and the field above it"
    assert_backends_agree(prog, frames: [1, 2], name: "BARLOOP")
  end

  # ...and a bar whose routine the loop first calls some passes in shows from the first frame too,
  # and stays as the routine puts it up.
  def test_a_bar_put_up_later_in_the_game_loop_shows_from_the_first_frame
    prog = routine_bar_game do
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      step = var :step, 0
      game_loop do
        call :put_up_bar if step >= 4
        step += 1
      end
    end
    bottom = screen_height - 4

    assert_equal GREEN, picture(prog, 1).pixel(8, bottom), "the bar, on the first frame"
    assert_equal GREEN, picture(prog, 8).pixel(8, bottom), "and once the routine has put it up"
    assert_backends_agree(prog, frames: [1, 8], name: "BARLATE")
  end

  # ...with the field put up by a routine called before the loop,
  def test_a_bar_shows_with_a_field_put_up_by_a_routine_before_the_loop
    prog = routine_bar_game do
      step = var :step, 0
      func(:put_up_field) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      call :put_up_field
      game_loop do
        call :put_up_bar if step >= 2
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 1).pixel(8, screen_height - 4)
    assert_backends_agree(prog, frames: [1, 4], name: "BARFUNC")
  end

  # ...or inside a test before the loop,
  def test_a_bar_shows_with_a_field_put_up_inside_a_test_before_the_loop
    prog = routine_bar_game do
      step = var :step, 0
      wanted = var :wanted, 1
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } if wanted == 1
      game_loop do
        call :put_up_bar if step >= 2
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 1).pixel(8, screen_height - 4)
    assert_backends_agree(prog, frames: [1, 4], name: "BARIF")
  end

  # ...or first in the loop, where the frame after the pass that puts the field up shows the bar,
  def test_a_bar_shows_with_a_field_first_put_up_in_the_loop
    prog = routine_bar_game do
      step = var :step, 0
      func(:put_up_field) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      game_loop do
        call :put_up_field
        call :put_up_bar if step >= 2
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 2).pixel(8, screen_height - 4)
    assert_backends_agree(prog, frames: [1, 2, 4], name: "BARFIELDLOOP")
  end

  # ...or as a scene's own field comes up.
  def test_a_bar_shows_with_a_scenes_field
    prog = routine_bar_game do
      step = var :step, 0
      state = var :state, 0
      scene(:play) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      game_loop do
        case_var(:state) { when_val 0, :play }
        call :put_up_bar if step >= 3
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 2).pixel(8, screen_height - 4)
    assert_backends_agree(prog, frames: [1, 2, 5], name: "BARSCENE")
  end

  # A bar moved in the pass its field first goes up shows at the row it was moved to on that frame:
  # nothing has put it up from its corner.
  def test_a_bar_moved_in_the_pass_its_field_first_goes_up_shows_moved
    prog = program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      step = var :step, 0
      bar = nil
      func(:put_up_bar) { bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16 }
      func(:put_up_field) do
        background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
        bar.move_to screen_height - 40
      end
      game_loop do
        call :put_up_field
        call :put_up_bar if step >= 3
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 2).pixel(8, screen_height - 30), "the bar's moved top"
    assert_backends_agree(prog, frames: [1, 2, 6], name: "BARMOVED")
  end

  # A bar placed before anything has put it up shows at the row it was placed at, from the first
  # background put up: only its own line puts it at the row it was declared with.
  def test_a_bar_placed_before_it_first_goes_up_shows_where_it_was_placed
    prog = movable_bar_game do
      step = var :step, 0
      call :move_bar
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      game_loop do
        call :put_up_bar if step >= 3
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 1).pixel(8, screen_height - 30), "the bar's placed top"
    assert_backends_agree(prog, frames: [1, 2, 6], name: "BARPLACED")
  end

  # ...and one placed in an earlier pass stays there while its field goes up again on every pass.
  def test_a_bar_placed_in_an_earlier_pass_stays_placed_as_its_field_goes_up_again
    prog = movable_bar_game do
      step = var :step, 0
      func(:put_up_field) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      game_loop do
        call :put_up_field
        call :move_bar if step == 0
        call :put_up_bar if step >= 5
        step += 1
      end
    end

    assert_equal GREEN, picture(prog, 4).pixel(8, screen_height - 30), "the bar's placed top"
    assert_backends_agree(prog, frames: [1, 2, 4, 8], name: "BARPLACEDEARLIER")
  end

  # A bar declared in one scene is up in that scene alone: the scene after it shows its field to
  # the bottom of the screen.
  def test_a_bar_belongs_to_the_scene_that_declares_it
    prog = scene_leaves_and_comes_back do
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
    end
    bottom = screen_height - 4

    assert_equal GREEN, picture(prog, 4).pixel(8, bottom)
    assert_equal RED, picture(prog, 6).pixel(8, bottom)
    assert_backends_agree(prog, frames: [4, 6], name: "BARSCN")
  end

  # A scene whose bar was moved and had a cell changed comes back with its bar as declared, at the
  # row it was declared with, until the game places it again — as a background comes back to its
  # corner and its first map.
  def test_a_scene_that_comes_back_puts_its_bar_up_as_declared
    prog = scene_leaves_and_comes_back do |tick|
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      bar.move_to 40 if tick == 2
      bar.set_tile 1, 0, "o" if tick == 3
    end

    assert_equal GREEN, picture(prog, 4).pixel(20, 44), "moved up"
    assert_equal BLUE, picture(prog, 4).pixel(12, 44), "and a cell of it changed"
    assert_backends_agree(prog, frames: [4, 8, 9, 10, 12], name: "BARBACK")
  end
end
