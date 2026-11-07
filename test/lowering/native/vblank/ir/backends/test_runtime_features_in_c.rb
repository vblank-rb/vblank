# frozen_string_literal: true

require "test_helper"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's C only when its steps need it:
# game.c includes its header, and the file the C screen includes takes in its code and its hooks.
class TestRuntimeFeaturesInC < Minitest::Test
  include VBlank::IR::Build

  Native = VBlank::IR::Backends::Native
  Features = VBlank::IR::Backends::RuntimeFeatures

  private def features_text(program) = Features.c_text(Native::Lowering.new(program).runtime_features)

  def test_a_game_that_pixelates_takes_in_pixelation
    pixelates = program(screen(:bitmap), pixelate(size: int(4)), halt)

    assert_includes Native.new.lower(pixelates), %(#include "pixelation/rg_pixelation.h")
    assert_includes features_text(pixelates), %(#include "pixelation/rg_pixelation.c")
    assert_includes features_text(pixelates), "rg_pixelation_paint_scenery(background)"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "pixelation"
    refute_includes features_text(plain), "pixelation"
  end

  # The screen's own file names no feature: it calls its hooks, and a hook nobody takes does what
  # the screen does alone.
  def test_the_screen_file_names_no_feature
    screen = File.read(File.join(Native::Zig::RUNTIME_DIR, "rg_screen.c"))

    refute_match(/pixelat|read_block/, screen)
  end
end
