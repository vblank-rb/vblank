# frozen_string_literal: true

require "test_helper"

# Small games with a status bar, shared by the tests of the `status_bar` verb
# (test/all/vblank/builder/test_status_bar.rb) and of its handle (test/all/vblank/dsl/test_status_bar.rb).
# Every game is laid out from the size of the console the run plays it on, so it plays on the
# Advance and on the Color alike.
module StatusBarGames
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLACK = VBlank::Graphics::Color.resolve(:black)

  # How tall a bar's picture is in these games: two rows of tiles.
  BAR_HEIGHT = 16

  private

  # A program built for this run's console, so its `screen_height` is that console's.
  def program(&block)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A field of red tiles with a blue row every fourth row, scrolled down a pixel a pass, and a
  # green bar two rows tall whose top is at the bottom of the screen less +from_bottom+. The game
  # loop's body is handed the bar and a counter of the passes.
  def bar_game(from_bottom: BAR_HEIGHT, &body)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art, "o" => :blue_art
      tiles :bar_tiles, "#" => :green_art, "o" => :blue_art
      field = background :field, tiles: :field_tiles,
                                 map: Array.new(32) { |r| ((r % 4).zero? ? "o" : "#") * 32 }
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - from_bottom
      step = 0
      game_loop do
        field.scroll_by 0, 1
        instance_exec(bar, step, &body) if body
        step += 1
      end
    end
  end

  # The same field under a bar with two maps, all green and all blue. The game loop's body is
  # handed the bar and a counter of the passes.
  def bar_game_with_maps(&body)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art, "o" => :blue_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      bar = status_bar :score, tiles: :bar_tiles, top: screen_height - BAR_HEIGHT,
                               map: { green: ["#" * 32, "#" * 32], blue: ["o" * 32, "o" * 32] }
      step = 0
      game_loop do
        instance_exec(bar, step, &body)
        step += 1
      end
    end
  end

  def screen_height = VBlank::Console.described(game_console).screen_height

  def screen_width = VBlank::Console.described(game_console).screen_width

  def picture(prog, frames) = game_player.run(prog, frames: frames).screen
end

# A bar's cell changed with `now: true`, played by each console that can show one: however the
# console times it, the cell is the same in the pass's picture.
module BarCellShownNowTests
  include StatusBarGames

  def test_a_bar_cell_changed_now_shows_the_tile_it_was_given
    screen = picture(bar_game { |bar, step| bar.set_tile 1, 0, "o", now: true if step == 2 }, 6)
    row = screen_height - BAR_HEIGHT + 4

    assert_equal BLUE, screen.pixel(12, row)
    assert_equal GREEN, screen.pixel(28, row)
  end
end
