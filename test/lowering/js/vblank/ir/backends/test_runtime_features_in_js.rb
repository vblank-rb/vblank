# frozen_string_literal: true

require "test_helper"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's JavaScript only when its steps
# need it.
class TestRuntimeFeaturesInJS < Minitest::Test
  include VBlank::IR::Build

  JS = VBlank::IR::Backends::JS

  def test_a_game_that_pixelates_takes_in_pixelation
    text = JS.new.factory(program(screen(:bitmap), pixelate(size: int(4)), halt))

    assert_includes text, "function rg_pixelation_paint_scenery("
    assert_includes text, "return rg_pixelation_paint_scenery(background);"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_pixelation"
    refute_includes text, "function rg_screen_pixelate("
  end

  def test_the_screen_file_names_no_feature
    refute_match(/pixelat|read_block/, File.read(File.join(JS::RUNTIME_DIR, "rg_screen.js")))
  end
end
