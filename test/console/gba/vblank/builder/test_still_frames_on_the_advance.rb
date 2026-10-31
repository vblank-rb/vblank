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

  STRIPES = Ractor.make_shareable(Array.new(32) { ("#" * 16) + ("o" * 16) })
  CHECKERS = Ractor.make_shareable(Array.new(32) { |row| (row.even? ? "#o" : "o#") * 16 })

  # The picture on the last frame before the game changes its one thing, and on the last of all.
  private def picture_before_and_after(prog)
    [CHANGE_AT - 1, FRAMES].map { |frames| game_player.run(prog, frames: frames).screen.to_a }
  end

  private def assert_picture_changes(prog)
    before, after = picture_before_and_after(prog)

    refute_equal before, after, "the picture should be different once the game has changed it"
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

  # --- a layer the display sees through, coming and going ---

  private def glass_over_red(from:, to:)
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
end
