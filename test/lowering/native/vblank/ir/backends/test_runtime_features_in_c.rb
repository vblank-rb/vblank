# frozen_string_literal: true

require "test_helper"
require "runtime_feature_games"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's C only when its steps need it:
# game.c includes its header, and the file the C screen includes takes in its code and its hooks.
class TestRuntimeFeaturesInC < Minitest::Test
  include VBlank::IR::Build
  include RuntimeFeatureGames

  Native = VBlank::IR::Backends::Native
  Features = VBlank::IR::Backends::RuntimeFeatures

  private def features_text(program) = Features.c_text(Native::Lowering.new(program).runtime_features)

  # The scroll of a background declared only where no run reaches compiles: the feature is taken in.
  def test_a_background_declared_in_an_uncalled_routine_still_takes_it_in
    assert_includes features_text(game_scrolling_a_background_declared_in_an_uncalled_routine),
                    %(#include "tiled/rg_tiled.c")
  end

  def test_a_game_with_a_sprite_takes_in_the_sprites_feature
    sprites = game_with_a_sprite

    assert_includes Native.new.lower(sprites), %(#include "sprites/rg_sprites.h")
    assert_includes features_text(sprites), %(#include "sprites/rg_sprites.c")
    assert_includes features_text(sprites), "rg_sprites_paint_level(level)"
  end

  def test_a_game_with_no_sprite_holds_none_of_the_sprites_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_sprites"
    refute_includes features_text(plain), "rg_sprites"
  end

  # Sprites are painted after the scenery of their level, so the feature is taken after tiled.
  def test_the_sprites_feature_comes_after_the_tiled_one
    text = features_text(game_with_a_background_and_a_sprite)

    assert_operator text.index("tiled/rg_tiled.c"), :<, text.index("sprites/rg_sprites.c")
    assert_operator text.index("rg_tiled_paint_level(level);"), :<, text.index("rg_sprites_paint_level(level);")
  end

  def test_a_game_that_pixelates_takes_in_pixelation
    pixelates = program(screen(:bitmap), pixelate(size: int(4)), halt)

    assert_includes Native.new.lower(pixelates), %(#include "pixelation/rg_pixelation.h")
    assert_includes features_text(pixelates), %(#include "pixelation/rg_pixelation.c")
    assert_includes features_text(pixelates), "rg_pixelation_block_size()"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "pixelation"
    refute_includes features_text(plain), "pixelation"
  end

  def test_a_game_with_a_background_takes_in_the_tiled_feature
    tiled = game_with_a_background

    assert_includes Native.new.lower(tiled), %(#include "tiled/rg_tiled.h")
    assert_includes features_text(tiled), %(#include "tiled/rg_tiled.c")
    assert_includes features_text(tiled), "rg_tiled_paint_level(level)"
  end

  def test_a_game_with_no_background_holds_none_of_the_tiled_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_tiled"
    refute_includes features_text(plain), "rg_tiled"
  end

  # The screen's own files name no feature: they call their hooks, and a hook nobody takes does
  # what the screen does alone.
  def test_the_screen_files_name_no_feature
    screen = File.read(File.join(Native::Zig::RUNTIME_DIR, "rg_screen.c"))
    header = File.read(File.join(Native::Zig::RUNTIME_DIR, "rg_screen.h"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen + header)
    refute_match(SPRITES_NAMES, screen + header)
  end
end
