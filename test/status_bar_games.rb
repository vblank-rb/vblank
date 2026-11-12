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
  WHITE = VBlank::Graphics::Color.resolve(:white)
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

  # A white sprite sixteen rows tall that the stack puts behind a red field, standing half over the top of
  # a green bar two rows tall. The game loop's body is handed the bar and a counter of the passes.
  def sprite_behind_field_game(&body)
    program do
      screen :tiled
      layers :back, :world
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:ball, "#" => :white) { (["########"] * 16).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      layer(:back) { sprite :ball, at: [40, screen_height - 24] }
      layer(:world) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      step = 0
      game_loop do
        instance_exec(bar, step, &body) if body
        step += 1
      end
    end
  end

  # A game of two scenes over a red field, each with a bar of its own, and a white sprite standing on
  # both bars: the first scene, from the first pass, tells its green bar to cover sprites; the second,
  # from pass 4, never tells its blue bar.
  def two_scene_bars_game
    program do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:ball, "#" => :white) { (["########"] * 8).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :menu_tiles, "#" => :green_art
      tiles :score_tiles, "#" => :blue_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      sprite :ball, at: [40, screen_height - 12]
      state = var :state, 0
      tick = var :tick, 0
      scene(:menu) do
        bar = status_bar :menu_bar, tiles: :menu_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
        bar.covers_sprites = true
      end
      scene(:play) { status_bar :score_bar, tiles: :score_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16 }
      game_loop do
        tick += 1
        state = 1 if tick == 4
        case_var(:state) do
          when_val 0, :menu
          when_val 1, :play
        end
      end
    end
  end

  # A white sprite eight rows tall standing half over the top of a bar two rows tall, on a field.
  # The game loop's body is handed the bar and a counter of the passes.
  def bar_game_under_a_sprite(&body)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:ball, "#" => :white) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - BAR_HEIGHT
      sprite :ball, at: [40, screen_height - BAR_HEIGHT - 4]
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

# A sprite the stack puts behind the field, beside a bar, played by each console that draws the bar
# behind every sprite whatever the stack says (the Color puts such a sprite behind its bar too, and
# refuses the game: Checks::StatusBarCannotShare).
module SpriteBehindFieldOverBarTests
  include StatusBarGames

  # The field hides the sprite above the bar's top, and the sprite shows over the bar below it: the
  # field is not drawn under the bar.
  def test_a_sprite_behind_the_field_shows_over_the_bar
    shown = picture(sprite_behind_field_game, 4)

    assert_equal RED, shown.pixel(44, screen_height - 20), "the field covers the sprite above the bar"
    assert_equal WHITE, shown.pixel(44, screen_height - 12), "the sprite shows over the bar"
    assert_equal GREEN, shown.pixel(8, screen_height - 12)
  end
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
