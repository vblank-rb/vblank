# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_still_frames"

# THE TESTS OF all/vblank/builder/test_still_frames.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept
# apart so that the Color's run never loads them (test/console/gba): a tint of the picture
# the display mixes in, a fade placed in the stack, a layer the display sees through, a
# background that turns, and a picture shown in blocks. Each holds the scroll and the sprite still
# and changes one of those on one frame, as the tests there do, and the runs that check every
# frame hold every frame after it to the interpreter's.
class TestStillFramesOnTheAdvance < Minitest::Test
  include StillFrameGames

  WHITE = VBlank::Graphics::Color.resolve(:white)
  STRIPES = Ractor.make_shareable(Array.new(32) { ("#" * 16) + ("o" * 16) })
  CHECKERS = Ractor.make_shareable(Array.new(32) { |row| (row.even? ? "#o" : "o#") * 16 })

  # The picture on the last frame before the game changes its one thing, and on the last of all:
  # every twentieth pixel each way of what is shown, with any fade or tint mixed in.
  private def picture_before_and_after(prog)
    [CHANGE_AT - 1, FRAMES].map do |frames|
      screen = game_player.run(prog, frames: frames).screen
      (0...160).step(20).flat_map { |y| (0...240).step(20).map { |x| screen.pixel(x, y) } }
    end
  end

  private def assert_picture_changes(prog)
    before, after = picture_before_and_after(prog)

    refute(before == after, "the picture should be different once the game has changed it")
  end

  def test_a_tint_begun_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        tint :green, 100 if tick == CHANGE_AT
      end
    end

    assert_equal GREEN, shown_at_the_end(prog)
  end

  def test_a_tint_that_lifts_on_a_still_screen_shows_the_picture_again
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        tint :green, 100 if tick < CHANGE_AT
        tint :green, 0 if tick == CHANGE_AT
      end
    end

    assert_equal RED, shown_at_the_end(prog)
  end

  # A scene that comes back puts both its backgrounds up again, each shown from its corner for the
  # pass it arrives in. The first is scrolled again every frame. The second was scrolled once, the
  # first time, and nothing says it again: it is the corners going that move it to where it was
  # scrolled, with no scroll said and no sprite moved to ask for the picture.
  def test_a_scene_coming_back_on_a_still_screen_shows_a_background_nobody_scrolls_again
    prog = still_game do
      state = var :state, 0
      tick = var :tick, 0
      scene(:bare) {}
      scene(:covered) do
        background(:below, tiles: :set, map: RED_FIELD).scroll_to(*SCROLL)
        background(:columns, tiles: :set, map: COLUMNS).scroll_to(*SCROLL) if tick == 2
      end
      game_loop do
        tick += 1
        state = 1 if tick == 2
        state = 0 if tick == 5
        state = 1 if tick == CHANGE_AT + 4
        case_var(:state) do
          when_val 0, :bare
          when_val 1, :covered
        end
      end
    end

    assert_equal BLUE, shown_at_the_end(prog, COLUMN_PIXEL)
  end

  # A scene that says its own backdrop takes over from one that covers the screen: the colour shown
  # wherever nothing is drawn is now the scene's.
  def test_a_scenes_own_backdrop_on_a_still_screen_shows
    prog = still_game do
      state = var :state, 1
      tick = var :tick, 0
      scene(:sky) { screen :tiled, backdrop: :blue }
      scene(:covered) { background(:cover, tiles: :set, map: RED_FIELD).scroll_to(*SCROLL) }
      game_loop do
        tick += 1
        state = 0 if tick == CHANGE_AT
        case_var(:state) do
          when_val 0, :sky
          when_val 1, :covered
        end
      end
    end

    assert_equal BLUE, shown_at_the_end(prog)
  end

  # --- a fade placed in the stack: what is behind a layer goes dark, and what is in front stays ---

  private def fade_under_actors(amount_after)
    program do
      screen :tiled
      layers :world, :actors
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:ball, "#" => :white) { SOLID_TILE }
      tiles :set, "#" => :red_art
      field = nil
      layer(:world) { field = background :field, tiles: :set, map: RED_FIELD }
      layer(:actors) { sprite :ball, at: [120, 90] }
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        fade :black, amount_after, under: :actors if tick == CHANGE_AT
      end
    end
  end

  def test_a_fade_placed_under_a_layer_on_a_still_screen_darkens_what_is_behind_it
    assert_equal BLACK, shown_at_the_end(fade_under_actors(100))
  end

  def test_a_fade_placed_under_a_layer_that_lifts_on_a_still_screen_shows_the_picture_again
    prog = program do
      screen :tiled
      layers :world, :actors
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:ball, "#" => :white) { SOLID_TILE }
      tiles :set, "#" => :red_art
      field = nil
      layer(:world) { field = background :field, tiles: :set, map: RED_FIELD }
      layer(:actors) { sprite :ball, at: [120, 90] }
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        fade :black, 100, under: :actors if tick < CHANGE_AT
        fade :black, 0, under: :actors if tick == CHANGE_AT
      end
    end

    assert_equal RED, shown_at_the_end(prog)
  end

  # A tint takes the place of whatever fade was in force, one placed in the stack included, and a
  # placed fade is painted into the picture, so the picture is built again as it goes.
  def test_a_tint_that_takes_the_place_of_a_placed_fade_on_a_still_screen_shows_the_picture_under_it
    alone = tinted_field(placed_fade_first: false)
    after_a_fade = tinted_field(placed_fade_first: true)

    assert_equal shown_at_the_end(alone), shown_at_the_end(after_a_fade)
  end

  # A red field half tinted green from frame +CHANGE_AT+, with or without a fade placed under the
  # sprite's layer, black, until then.
  private def tinted_field(placed_fade_first:)
    program do
      screen :tiled
      layers :world, :actors
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:ball, "#" => :white) { SOLID_TILE }
      tiles :set, "#" => :red_art
      field = nil
      layer(:world) { field = background :field, tiles: :set, map: RED_FIELD }
      layer(:actors) { sprite :ball, at: [120, 90] }
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        fade :black, 100, under: :actors if placed_fade_first && tick < CHANGE_AT
        tint :green, 50 if tick == CHANGE_AT
      end
    end
  end

  # --- a layer the display sees through, coming and going ---

  private def glass_over_red(from:, to:, fade_whole_screen: false)
    program do
      screen :tiled
      layers :deep, :glass
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:blue_art, "#" => :blue) { SOLID_TILE }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      amount = var :amount, from
      deep = nil
      glass = nil
      layer(:deep) { deep = background :deep, tiles: :red_set, map: RED_FIELD }
      layer(:glass, transparency: amount) { glass = background :glass, tiles: :blue_set, map: RED_FIELD }
      tick = var :tick, 0
      game_loop do
        deep.scroll_to(*SCROLL)
        glass.scroll_to(*SCROLL)
        tick += 1
        amount = to if tick == CHANGE_AT
        fade :black, 50 if fade_whole_screen && tick == CHANGE_AT
      end
    end
  end

  def test_a_layer_that_becomes_solid_on_a_still_screen_shows
    assert_equal BLUE, shown_at_the_end(glass_over_red(from: 100, to: 0))
  end

  def test_a_layer_that_becomes_invisible_on_a_still_screen_is_gone
    assert_equal RED, shown_at_the_end(glass_over_red(from: 0, to: 100))
  end

  def test_a_layer_that_becomes_half_seen_through_on_a_still_screen_mixes
    prog = glass_over_red(from: 0, to: 50)

    refute_includes [RED, BLUE], shown_at_the_end(prog)
  end

  # A fade over the whole screen takes the display's blend from a see-through layer, which is
  # solid until the fade lifts: the layer changes without its own amount being touched.
  def test_a_fade_that_takes_the_blend_from_a_layer_on_a_still_screen_makes_it_solid
    prog = glass_over_red(from: 50, to: 50, fade_whole_screen: true)

    assert_picture_changes prog
  end

  # --- what changes the picture's shape ---

  def test_a_background_turned_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      turner = background :turner, tiles: :set, map: STRIPES
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        turner.rotate 90 if tick == CHANGE_AT
      end
    end

    assert_picture_changes prog
  end

  def test_a_picture_put_into_blocks_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: CHECKERS
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        pixelate 8 if tick == CHANGE_AT
      end
    end

    assert_picture_changes prog
  end

  # --- what changes the picture without saying so: each is a write to the picture that is not
  # the rebuild, so the picture is no longer the one the last rebuild painted ---

  # A new backdrop with no scenery up is laid straight over the whole picture, sprites and all.
  def test_a_scene_changing_the_backdrop_keeps_a_still_sprite
    prog = still_game do
      state = var :state, 0
      tick = var :tick, 0
      scene(:first) { screen :tiled, backdrop: :black }
      scene(:second) { screen :tiled, backdrop: :blue }
      scene(:never) { background(:cover, tiles: :set, map: RED_FIELD).scroll_to(*SCROLL) }
      game_loop do
        tick += 1
        state = 1 if tick == CHANGE_AT
        case_var(:state) do
          when_val 0, :first
          when_val 1, :second
          when_val 2, :never
        end
      end
    end
    screen = game_player.run(prog, frames: FRAMES).screen

    assert_equal [WHITE, BLUE], [screen.pixel(*BALL_PIXEL), screen.pixel(*CELL_PIXEL)]
  end

  # Taking a scene's scenery down lays what stays up back from its corner. With no sprite up
  # nothing else asks, and the scroll said next is the number already stored.
  def test_scenery_left_by_a_scene_going_shows_where_it_is_scrolled
    prog = still_game do |ball|
      ball.hide
      field = background :field, tiles: :set, map: COLUMNS
      state = var :state, 0
      tick = var :tick, 0
      scene(:covered) { background(:cover, tiles: :set, map: RED_FIELD) }
      scene(:bare) {}
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        state = 1 if tick == CHANGE_AT
        case_var(:state) do
          when_val 0, :covered
          when_val 1, :bare
        end
      end
    end

    assert_equal BLUE, shown_at_the_end(prog, COLUMN_PIXEL)
  end

  # A tear-free screen is two pages shown in turn, and a rebuild paints only one of them. A sprite
  # that moves once and stops must end up moved on both, or it jumps back on every other frame.
  def test_a_sprite_that_stops_on_a_tear_free_screen_stands_in_one_place_on_both_pages
    tile = SOLID_TILE
    prog = program do
      screen :bitmap, tear_free: true
      image(:red_art, "#" => :red) { tile }
      image(:ball, "#" => :white) { tile }
      tiles :set, "#" => :red_art
      field = background :field, tiles: :set, map: RED_FIELD
      ball = sprite :ball, at: [120, 90]
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        ball.x += 8 if tick == CHANGE_AT
      end
    end
    last_two = [FRAMES, FRAMES + 1].map { |frames| game_player.run(prog, frames: frames).screen.pixel(*BALL_PIXEL) }

    assert_equal [RED, RED], last_two
  end
end
