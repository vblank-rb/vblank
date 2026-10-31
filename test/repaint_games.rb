# frozen_string_literal: true

require "test_helper"

# Two small tiled games for the tests of how often a run builds the whole view again, shared by
# the native, JavaScript and Ruby lowerings' own tests (test/lowering/*/.../test_*_repaints.rb).
# Both scroll a background and stand a sprite still, so both are screens that are rebuilt whole;
# one holds its scroll where it is and the other moves it every frame.
module RepaintGames
  # A program built for this run's console, which the game is then played as.
  private def repaint_program(&block)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console))
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # A scrolled field and a sprite that never move: each frame says the same scroll.
  private def still_game
    tile = Minitest::Test::SOLID_TILE
    repaint_program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:ball, "#" => :white) { tile }
      tiles :set, "#" => :red_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      sprite :ball, at: [120, 90]
      game_loop { field.scroll_to 3, 5 }
    end
  end

  # The same field scrolled a pixel further every frame.
  private def scrolling_game
    tile = Minitest::Test::SOLID_TILE
    repaint_program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:ball, "#" => :white) { tile }
      tiles :set, "#" => :red_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      sprite :ball, at: [120, 90]
      game_loop { field.scroll_by 1, 0 }
    end
  end
end
