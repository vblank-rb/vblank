# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# A GAME LAID OUT FOR THE GAME BOY COLOR, ON THE ADVANCE'S CARTRIDGE (Backends::GBA::BorderSprites):
# its 160×144 picture at its own size in the middle of the 240×160 screen, a border round it, read
# back in the emulator.
module BorderGames
  # A tiled game: a field of red and green columns that scrolls right while RIGHT is held, and a
  # white square standing half off the left edge of the game's screen, which moves down a pixel a
  # frame. Every place of it says where the corner of the game's screen is.
  TILED = Ractor.make_shareable(VBlank.game("BORDERT", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image :red_tile, "#" => :red do "########\n" * 8 end
    image :green_tile, "#" => :green do "########\n" * 8 end
    tiles :ground, "r" => :red_tile, "g" => :green_tile
    field = background :field, tiles: :ground, map: Array.new(32) { |row| Array.new(32) { |col| (col + row).even? ? "r" : "g" }.join }
    image :square, "#" => :white do "########\n" * 8 end
    square = sprite :square, at: [-4, 20]
    game_loop do
      field.scroll_by 1, 0 if held(:right)
      square.y += 1
    end
  end)

  # A painted game: four bars of colour across the top of the game's screen, and a box that moves
  # right a pixel a frame.
  PAINTED = Ractor.make_shareable(VBlank.game("BORDERP", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :bitmap
    x = var :x, 0
    game_loop do
      clear_screen :black
      fill_rect 0, 0, 40, 8, :red
      fill_rect 40, 0, 40, 8, :green
      fill_rect 80, 0, 40, 8, :blue
      fill_rect 120, 0, 40, 8, :white
      draw_rect_at x, 100, 8, 8, :yellow
      x += 1
    end
  end)

  # The tiled game's field again with a border of its own, drawn as text art: a pattern of two
  # colours repeated across the whole screen.
  PATTERNED = Ractor.make_shareable(VBlank.game("BORDERA", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    border "#" => :blue, "." => :yellow do
      "#.\n.#\n"
    end
    image :red_tile, "#" => :red do "########\n" * 8 end
    tiles :ground, "r" => :red_tile
    background :field, tiles: :ground, map: Array.new(32) { "r" * 32 }
    game_loop { wait_vblank }
  end)

  # ...and a border given as a picture of the whole screen: the top half cyan, the bottom magenta.
  WHOLE = Array.new(240 * 160) { |at| at / 240 < 80 ? :cyan : :magenta }.freeze
  PICTURED = Ractor.make_shareable(VBlank.game("BORDERW", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :bitmap
    border width: 240, height: 160, data: WHOLE
    game_loop { clear_screen :black }
  end)

  # A tiled game with two sprites standing still, for reading them back off the cartridge.
  STILL = Ractor.make_shareable(VBlank.game("BORDERS", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image :red_tile, "#" => :red do "########\n" * 8 end
    tiles :ground, "r" => :red_tile
    background :field, tiles: :ground, map: Array.new(32) { "r" * 32 }
    image :square, "#" => :white do "########\n" * 8 end
    image :bar, "#" => :blue do "################\n" * 8 end
    sprite :square, at: [30, 20]
    sprite :bar, at: [100, 120]
    game_loop { wait_vblank }
  end)

  # A tiled game that fades its whole picture half way to black.
  FADED = Ractor.make_shareable(VBlank.game("BORDERF", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :tiled
    image :red_tile, "#" => :red do "########\n" * 8 end
    tiles :ground, "r" => :red_tile
    background :field, tiles: :ground, map: Array.new(32) { "r" * 32 }
    fade :black, 50
    game_loop { wait_vblank }
  end)
end

class TestBorderSprites < Minitest::Test
  include Differential

  LEFT = 40
  TOP = 8

  private def cartridge(game) = game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new)

  # VBlank's own border, as the build draws it, at (x, y) on the whole screen.
  private def default_border_at(x, y)
    VBlank::Graphics::Border.default(whole: [240, 160], inner: [160, 144])[(y * 240) + x]
  end

  def test_a_color_game_shows_at_its_own_size_in_the_middle_with_the_default_border
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::TILED), frames: 6)

    [[0, 0], [239, 0], [0, 159], [239, 159], [LEFT - 1, 80], [LEFT + 160, 80], [120, TOP - 1], [120, TOP + 144]]
      .each do |x, y|
        assert_equal default_border_at(x, y), v.pixel_gba(x, y), "the border at (#{x}, #{y})"
      end
    # The field's first cell, red, is at the game screen's corner, and the green one beside it.
    assert v.red?(LEFT, TOP), "the game's top-left pixel is at (40, 8)"
    assert v.green?(LEFT + 8, TOP), "...and its next cell eight across"
  end

  def test_a_sprite_half_off_the_edge_is_cut_at_the_edge_of_the_game_screen
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::TILED), frames: 6)

    whites = (0...160).select { |y| v.white?(LEFT, y) }
    refute_empty whites, "the right half of the square shows at the game screen's left edge"
    assert whites.all? { |y| y >= TOP && y < TOP + 144 }
    whites.each do |y|
      assert_equal default_border_at(LEFT - 1, y), v.pixel_gba(LEFT - 1, y),
                   "its left half is behind the border, not drawn over it, on row #{y}"
    end
  end

  def test_every_frame_of_the_game_screen_is_the_interpreters_on_a_tiled_screen
    assert_backends_agree(BorderGames::TILED.program(console: :gba), frames: [1, 3, 8, 20], keys: [:right])
  end

  def test_every_frame_of_the_game_screen_is_the_interpreters_on_a_painted_screen
    assert_backends_agree(BorderGames::PAINTED.program(console: :gba), frames: [1, 3, 8, 20])
  end

  def test_a_painted_game_lands_in_the_middle_too
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::PAINTED), frames: 6)

    assert v.red?(LEFT, TOP)
    assert v.green?(LEFT + 40, TOP)
    assert v.blue?(LEFT + 80, TOP)
    assert v.white?(LEFT + 159, TOP)
    assert_equal default_border_at(LEFT + 160, TOP), v.pixel_gba(LEFT + 160, TOP), "the screen ends at 160 across"
  end

  def test_a_border_drawn_as_text_art_is_repeated_round_the_screen
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::PATTERNED), frames: 6)

    assert v.blue?(0, 0)
    assert v.pixel_is?(1, 0, :yellow)
    assert v.pixel_is?(0, 1, :yellow)
    assert v.blue?(239, 159)
    assert v.red?(LEFT, TOP), "and the game inside it"
  end

  def test_a_border_given_as_a_picture_of_the_whole_screen_is_shown_round_the_game
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::PICTURED), frames: 6)

    assert v.pixel_is?(0, 0, :cyan)
    assert v.pixel_is?(239, 79, :cyan)
    assert v.pixel_is?(0, 80, :magenta)
    assert v.pixel_is?(239, 159, :magenta)
    assert v.black?(LEFT, TOP), "the game's own screen covers the picture's middle"
  end

  # The sprites read back off the cartridge are the game's, at the places the game gave them on its
  # own screen: none of the border's, and none moved by the border's corner.
  def test_reading_the_sprites_back_gives_the_games_own_places
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::STILL), frames: 6)

    assert_equal %i[bar square], v.sprites.map(&:name).sort
    assert_equal [[30, 20]], v.sprites(:square).map { |row| [row.x, row.y] }
    assert_equal [[100, 120]], v.sprites(:bar).map { |row| [row.x, row.y] }
  end

  def test_a_fade_darkens_the_game_screen_and_not_the_border
    require_emulator!
    v = assert_emulator_loads_rom(cartridge(BorderGames::FADED), frames: 6)

    refute v.red?(LEFT, TOP), "the game's screen is half way to black"
    assert_equal default_border_at(0, 0), v.pixel_gba(0, 0), "the border is as drawn"
    assert_equal default_border_at(LEFT - 1, TOP), v.pixel_gba(LEFT - 1, TOP)
  end
end
