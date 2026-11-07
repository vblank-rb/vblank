# frozen_string_literal: true

require "test_helper"
require "runtime_feature_games"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's Ruby only when its steps need it.
class TestRuntimeFeaturesInRuby < Minitest::Test
  include VBlank::IR::Build
  include RuntimeFeatureGames

  Ruby = VBlank::IR::Backends::Ruby

  def test_a_game_that_pixelates_takes_in_pixelation
    text = Ruby.new.live_source(program(screen(:bitmap), pixelate(size: int(4)), halt))

    assert_includes text, "def rg_pixelation_scenery_block_size"
    assert_includes text, "rg_pixelation_setup"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_pixelation"
    refute_includes text, "def rg_screen_pixelate("
  end

  def test_a_game_with_a_background_takes_in_the_tiled_feature
    text = Ruby.new.live_source(game_with_a_background)

    assert_includes text, "def rg_tiled_paint_level("
    assert_includes text, "rg_tiled_setup"
  end

  def test_a_background_declared_in_an_uncalled_routine_still_takes_it_in
    assert_includes Ruby.new.live_source(game_scrolling_a_background_declared_in_an_uncalled_routine),
                    "def rg_background_scroll("
  end

  def test_a_game_with_no_background_holds_none_of_the_tiled_feature
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_tiled"
    refute_includes text, "def rg_background_stamp("
  end

  def test_the_screen_file_names_no_feature
    screen = File.read(File.join(Ruby::RUNTIME_DIR, "rg_screen.rb"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen)
  end
end
