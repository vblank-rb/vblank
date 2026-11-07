# frozen_string_literal: true

require "test_helper"
require "runtime_feature_games"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's JavaScript only when its steps
# need it.
class TestRuntimeFeaturesInJS < Minitest::Test
  include VBlank::IR::Build
  include RuntimeFeatureGames

  JS = VBlank::IR::Backends::JS

  def test_a_game_that_pixelates_takes_in_pixelation
    text = JS.new.factory(program(screen(:bitmap), pixelate(size: int(4)), halt))

    assert_includes text, "function rg_pixelation_scenery_block_size("
    assert_includes text, "return rg_pixelation_scenery_block_size();"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_pixelation"
    refute_includes text, "function rg_screen_pixelate("
  end

  def test_a_game_with_a_background_takes_in_the_tiled_feature
    text = JS.new.factory(game_with_a_background)

    assert_includes text, "function rg_tiled_paint_level("
    assert_includes text, "rg_tiled_paint_level(level);"
  end

  def test_a_background_declared_in_an_uncalled_routine_still_takes_it_in
    assert_includes JS.new.factory(game_scrolling_a_background_declared_in_an_uncalled_routine),
                    "function rg_background_scroll("
  end

  def test_a_game_with_no_background_holds_none_of_the_tiled_feature
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_tiled"
    refute_includes text, "function rg_background_stamp("
  end

  def test_the_screen_file_names_no_feature
    screen = File.read(File.join(JS::RUNTIME_DIR, "rg_screen.js"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen)
  end
end
