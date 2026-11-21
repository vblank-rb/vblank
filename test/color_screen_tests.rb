# frozen_string_literal: true

require "differential"

# A game laid out for the Game Boy Color plays in the Advance's border as it does on the color
# (Console::AdvanceKit::COLOR_SCREEN). The games are for those two consoles alone, so each console's
# folder has a test file that includes ColorScreenTests, played on every run that plays games as
# either:
#
#   test/console/gba/vblank/console/test_color_screen_games.rb
#   test/console/gbc/vblank/console/test_color_screen_games_on_the_color.rb
#
# Each game is played as the run's console: as the Advance, the build with the border, its middle
# 160×144 held to the interpreter on every frame compared; as the Color, the Color's build of the
# same game, held to the interpreter the same way. What the border itself shows round them is read
# in the emulator in test/lowering/gba/vblank/ir/backends/gba/test_border_sprites.rb.
module ColorScreenGames
  # A red field with a blue row every fourth row that scrolls down a pixel a pass, a green status bar
  # two rows tall with a white cell at each end of its first row, and a white square walking down
  # through the bar. The bar starts at the foot of the screen and climbs a row a pass until its top
  # is 100 rows down; from the eighth pass it covers the sprites.
  BAR = Ractor.make_shareable(VBlank.game("BORDERBAR", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image(:red_art, "#" => :red) { "########\n" * 8 }
    image(:blue_art, "#" => :blue) { "########\n" * 8 }
    image(:green_art, "#" => :green) { "########\n" * 8 }
    image(:white_art, "#" => :white) { "########\n" * 8 }
    tiles :field_tiles, "#" => :red_art, "o" => :blue_art
    tiles :bar_tiles, "#" => :green_art, "w" => :white_art
    field = background :field, tiles: :field_tiles, map: Array.new(32) { |r| ((r % 4).zero? ? "o" : "#") * 32 }
    bar = status_bar :score, tiles: :bar_tiles, map: ["w#{'#' * 18}w#{'#' * 12}", "#" * 32], top: screen_height
    image(:square, "#" => :white) { "########\n" * 8 }
    square = sprite :square, at: [76, 80]
    top = screen_height
    step = 0
    game_loop do
      field.scroll_by 0, 1
      top -= 1 if top > 100
      bar.move_to top
      bar.covers_sprites = true if step == 8
      square.y += 1
      step += 1
    end
  end)

  # Two scenes: a red field under a green bar for four passes, then a blue field with no bar. The bar
  # is declared first, so the Advance draws it on the layer the blue field takes after it.
  BAR_THEN_NONE = Ractor.make_shareable(VBlank.game("BORDERTWO", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image(:red_art, "#" => :red) { "########\n" * 8 }
    image(:blue_art, "#" => :blue) { "########\n" * 8 }
    image(:green_art, "#" => :green) { "########\n" * 8 }
    tiles :red_tiles, "#" => :red_art
    tiles :blue_tiles, "#" => :blue_art
    tiles :bar_tiles, "#" => :green_art
    state = var :state, 0
    tick = var :tick, 0
    scene(:play) do
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: 120
      background :field, tiles: :red_tiles, map: Array.new(32) { "#" * 32 }
    end
    scene(:menu) { background :sky, tiles: :blue_tiles, map: Array.new(32) { "#" * 32 } }
    game_loop do
      tick += 1
      state = 1 if tick == 4
      case_var(:state) do
        when_val 0, :play
        when_val 1, :menu
      end
    end
  end)

  # A red field, a white square standing half off the left edge of the screen and a blue one in the
  # middle, and every sprite hidden on every third pass.
  HIDING = Ractor.make_shareable(VBlank.game("BORDERHIDE", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image(:red_art, "#" => :red) { "########\n" * 8 }
    tiles :field_tiles, "#" => :red_art
    background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
    image(:white_square, "#" => :white) { "########\n" * 8 }
    image(:blue_square, "#" => :blue) { "########\n" * 8 }
    sprite :white_square, at: [-4, 20]
    blue = sprite :blue_square, at: [76, 68]
    step = 0
    game_loop do
      hide_sprites if step % 3 == 1
      blue.x += 1
      step += 1
    end
  end)
end

module ColorScreenTests
  include Differential
  include ColorScreenGames

  def test_a_status_bar_that_moves_and_covers_sprites_plays_as_on_the_color
    assert_backends_agree(BAR.program(console: game_console), frames: 1..24)
  end

  def test_a_scene_with_no_bar_after_one_with_a_bar_plays_as_on_the_color
    assert_backends_agree(BAR_THEN_NONE.program(console: game_console), frames: 1..10)
  end

  def test_hiding_the_sprites_plays_as_on_the_color
    assert_backends_agree(HIDING.program(console: game_console), frames: 1..10)
  end
end
