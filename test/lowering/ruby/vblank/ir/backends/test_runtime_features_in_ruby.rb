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

    assert_includes text, "def rg_pixelation_block_size"
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

  def test_a_game_with_a_sprite_takes_in_the_sprites_feature
    text = Ruby.new.live_source(game_with_a_sprite)

    assert_includes text, "def rg_sprites_paint_level("
    assert_includes text, "rg_sprites_setup"
  end

  def test_a_game_with_no_sprite_holds_none_of_the_sprites_feature
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_sprites_setup"
    refute_includes text, "def rg_objects_end"
  end

  # Sprites are painted after the scenery of their level, so the feature is taken after tiled.
  def test_the_sprites_feature_comes_after_the_tiled_one
    text = Ruby.new.live_source(game_with_a_background_and_a_sprite)

    assert_operator text.index("rg_tiled_paint_level(level)"), :<, text.index("rg_sprites_paint_level(level)")
  end

  def test_a_game_that_fades_takes_in_the_fades_feature
    text = Ruby.new.live_source(game_that_fades)

    assert_includes text, "def rg_fades_fade_filter"
    assert_includes text, "rg_fades_setup"
  end

  def test_a_game_that_never_fades_holds_none_of_the_fades_feature
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_fades"
    refute_includes text, "def rg_screen_fade("
  end

  def test_a_game_with_a_light_takes_in_the_light_feature
    text = Ruby.new.live_source(game_with_a_light)

    assert_includes text, "def rg_light_dim_filter"
    assert_includes text, "rg_light_setup"
  end

  def test_a_game_with_no_light_holds_none_of_the_light_feature
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_light"
    refute_includes text, "def rg_screen_work_out_shade"
  end

  def test_a_game_with_a_column_takes_in_the_columns_feature
    assert_includes Ruby.new.live_source(game_with_a_column), "def rg_screen_column("
  end

  def test_a_game_with_no_column_holds_none_of_the_columns_feature
    refute_includes Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt)), "def rg_screen_column("
    refute_includes Ruby.new.live_source(game_with_a_face), "def rg_screen_column("
  end

  def test_a_game_with_a_face_takes_in_the_faces_feature
    text = Ruby.new.live_source(game_with_a_face)

    assert_includes text, "def rg_screen_face("
    assert_includes text, "rg_faces_setup"
  end

  def test_a_game_with_no_face_holds_none_of_the_faces_feature
    refute_includes Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt)), "rg_screen_face"
    refute_includes Ruby.new.live_source(game_with_a_column), "rg_faces"
  end

  def test_the_screen_file_names_no_feature
    screen = File.read(File.join(Ruby::RUNTIME_DIR, "rg_screen.rb"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen)
    refute_match(SPRITES_NAMES, screen)
    refute_match(FADES_NAMES, screen)
    refute_match(LIGHT_NAMES, screen)
    refute_match(COLUMNS_NAMES, screen)
    refute_match(FACES_NAMES, screen)
  end
end
