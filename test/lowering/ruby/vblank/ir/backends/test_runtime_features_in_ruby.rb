# frozen_string_literal: true

require "test_helper"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's Ruby only when its steps need it.
class TestRuntimeFeaturesInRuby < Minitest::Test
  include VBlank::IR::Build

  Ruby = VBlank::IR::Backends::Ruby

  def test_a_game_that_pixelates_takes_in_pixelation
    text = Ruby.new.live_source(program(screen(:bitmap), pixelate(size: int(4)), halt))

    assert_includes text, "def rg_pixelation_paint_scenery("
    assert_includes text, "rg_pixelation_setup"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    text = Ruby.new.live_source(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_pixelation"
    refute_includes text, "def rg_screen_pixelate("
  end

  def test_the_screen_file_names_no_feature
    refute_match(/pixelat|read_block/, File.read(File.join(Ruby::RUNTIME_DIR, "rg_screen.rb")))
  end
end
