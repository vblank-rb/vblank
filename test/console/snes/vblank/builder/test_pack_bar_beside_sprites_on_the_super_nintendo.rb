# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"
require "pack_background_tests"

# A STATUS BAR FROM THE DATA PACK OF FOUR-COLOUR TILES, WALKED UP FROM BLACK BANK BY BANK, above a
# row of a stage whose arena takes five of the console's eight sets of background colours and whose
# sprites fill the sprites' tile room only with each picture's copies sharing tiles. The made-up
# original keeps the bar's four banks of four colours in sixteen colours of colour memory; a list the
# game walks has its colours in a set to itself, so the four banks drawn as four sets leave the arena
# too few (Art#held_background_palette). The answer key is the made-up original: each bar cell drawn
# from its bank, under the arena's rows.
class TestPackBarBesideSpritesOnTheSuperNintendo < Minitest::Test
  include PackBackgroundGames

  SNES_OPTIONS = VBlank::Cartridge::Options.new(console: :snes)

  # Four tiles of four colours: each a pattern of places 1 to 3, but for its second column, place 0,
  # see-through.
  SEE_THROUGH_X = 1
  BAR_TILES = (0...4).map do |n|
    (0...64).map { |at| (at % 8) == SEE_THROUGH_X ? 0 : 1 + (((at % 8) + (at / 8) + n) % 3) }
  end.freeze
  BAR_ROWS = 32
  # Where the original keeps the bar's colours, map and tiles.
  BAR_COLORS_AT = 0x20
  BAR_MAP_AT = 0x40
  BAR_TILES_AT = 0x200
  # Sixteen colours in four banks of four, all different (place 0 of each bank is see-through).
  BAR_COLORS = (0...16).map { |at| ((at * 2) + 1) | ((at + 3) << 5) | ((30 - at) << 10) }.freeze
  # The bar's map, 32 cells across and 4 rows: each run of eight cells a tile in its own bank.
  BAR_WORDS = (0...128).map { |at| SNES_CELL.(at % 4, bank: (at / 8) % 4) }.freeze
  # A cell the game writes later at TOLD_COLUMN of the first row: a tile in a bank of the shared set
  # that no cell there shows, mirrored.
  TOLD = SNES_CELL.(3, bank: 2, mirrored: true)
  TOLD_COLUMN = 30

  # The arena's five sets of colours: a tile of fifteen colours of its own for each.
  ARENA_SETS = 5
  ARENA_COLORS = (0...(15 * ARENA_SETS)).map { |k| ((k + 1) * 271) % 0x8000 }.freeze
  ARENA_ROW = (0...32).map { |column| (97 + (column % ARENA_SETS)).chr }.join.freeze
  # The arena's first row, empty under the bar's first two banks: the backdrop shows through there.
  ARENA_FIRST_ROW = ((" " * 16) + ARENA_ROW[16..]).freeze

  # Two dozen pictures of 32x32 whose tiles are all different, each sprite showing one and drawn
  # with another list: one copy of each in each list is more tiles than the sprites have.
  SPRITES = 24
  SPRITE_PLACES = (0...SPRITES).map do |n|
    random = Random.new(n)
    Array.new(32 * 32) { random.rand(2) }
  end.freeze

  # Where each of a colour's red, green and blue starts.
  CHANNEL_SHIFTS = [0, 5, 10].freeze
  BACKDROP = 0x0000 # Black, which no screen here changes
  WHITE = 0x7FFF
  # A white square that climbs across the bar's row, right of the other sprites: its column, its
  # side, and the row it starts at.
  CROSSING_X = 220
  CROSSING_SIDE = 16
  CROSSING_START = 60
  # The frames the crossing tests play, and the rows the climbing square covers then, a pass either
  # way, above the bar's row and from it down.
  CROSSING_FRAMES = 40
  CROSSING_ROWS_ABOVE = ((CROSSING_START - CROSSING_FRAMES + 2)...BAR_ROWS).freeze
  CROSSING_ROWS_BELOW = (BAR_ROWS...(CROSSING_START - CROSSING_FRAMES - 1 + CROSSING_SIDE)).freeze
  # The pixels of a bar cell looked at.
  CELL_SPOTS = [[0, 0], [3, 5], [7, 2]].freeze

  private def bar_original(folder)
    tiles = BAR_TILES.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    copy = "\0".b * (BAR_TILES_AT + tiles.bytesize)
    copy[BAR_COLORS_AT, 32] = BAR_COLORS.pack("v*")
    copy[BAR_MAP_AT, BAR_WORDS.length * 2] = BAR_WORDS.pack("v*")
    copy[BAR_TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The stage, its bar shown alone above its row with +alone+, and its arena scrolled a pixel across
  # and down each pass with +scrolled+. With +crossing+ a white square of CROSSING_SIDE climbs a pixel
  # each pass from CROSSING_START at CROSSING_X, across the bar's row.
  private def stage(from, alone: false, scrolled: false, crossing: false)
    b = VBlank::Builder.new(options: SNES_OPTIONS)
    b.instance_eval do
      screen :tiled
      layers :scenery, :craft, :bar
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :bar_tiles, at: BAR_TILES_AT, count: BAR_TILES.length, colors: 4
        slots.numbers :bar_map, at: BAR_MAP_AT, count: BAR_WORDS.length, width: :half, signed: false
        slots.colors :bar_colors, at: BAR_COLORS_AT, count: BAR_COLORS.length
      end
      ARENA_SETS.times do |set|
        image(:"arena_#{set}", width: 8, height: 8, data: Array.new(64) { |at| ARENA_COLORS.fetch((set * 15) + (at % 15)) })
      end
      tiles :arena_tiles, ARENA_SETS.times.to_h { |set| [(97 + set).chr, :"arena_#{set}"] }
      colors :hero, %i[transparent white red]
      colors :hurt, %i[transparent yellow blue]
      SPRITES.times { |n| image(:"craft_#{n}", width: 32, height: 32, colors: :hero, places: SPRITE_PLACES.fetch(n)) }
      image(:crossing, width: CROSSING_SIDE, height: CROSSING_SIDE, colors: :hero, places: Array.new(CROSSING_SIDE**2, 1)) if crossing
      var :state, 0
      walk = var :walk, 0
      scene(:stage) do
        layer(:scenery) do
          arena = background :arena, tiles: :arena_tiles, map: [ARENA_FIRST_ROW, *Array.new(31) { ARENA_ROW }]
          arena.scroll_to walk, walk if scrolled
        end
        layer(:craft) do
          SPRITES.times { |n| sprite(:"craft_#{n}", at: [(n % 6) * 36, 40 + ((n / 6) * 34)]).draw_with :hurt }
          sprite(:crossing, at: [CROSSING_X, CROSSING_START]).move_to CROSSING_X, CROSSING_START - walk if crossing
        end
        layer(:bar) do
          bar = background :bar, tiles: pack[:bar_tiles], map: pack[:bar_map], colors: pack[:bar_colors], across: 32, cell: 8,
                                 above_row: BAR_ROWS, set_cells: [TOLD], alone: alone
          bar.set_cell TOLD_COLUMN, 0, TOLD if walk == 20
          banks = (0...4).to_h { |bank| [:"bar_colors_#{bank}", color_walk(:"bar_colors_#{bank}", from: :black)] }
          bar.draw_with banks, showing: walk
        end
      end
      game_loop do
        walk += 1
        case_var(:state) { when_val 0, :stage }
      end
    end
    b.finalize_program
    b.program
  end

  # The colour the bar's cell at +column+ of its first row shows at (+x+, +y+) of the cell, as drawn.
  private def bar_color(column, x, y)
    word = BAR_WORDS.fetch(column)
    BAR_COLORS.fetch((((word >> 10) & 7) * 4) + BAR_TILES.fetch(word & 0x3FF).fetch((y * 8) + x))
  end

  def test_a_bar_of_four_colour_banks_from_the_pack_walks_up_beside_an_arena_and_sprites
    Dir.mktmpdir do |folder|
      program = stage(bar_original(folder))

      walking = game_player.run(program, frames: 3).screen

      [0, 9, 17, 26].each do |column|
        drawn = bar_color(column, 0, 0)
        early = walking.pixel(column * 8, 0)
        refute_equal drawn, early, "the bar's cell #{column} early in its walk"
        assert CHANNEL_SHIFTS.all? { |at| ((early >> at) & 31) <= ((drawn >> at) & 31) }, "the bar's cell #{column} walks up from black"
      end

      shown = game_player.run(program, frames: 40).screen

      [0, 9, 17, 26].each do |column|
        CELL_SPOTS.each do |x, y|
          assert_equal bar_color(column, x, y), shown.pixel((column * 8) + x, y), "the bar's cell #{column} at (#{x}, #{y})"
        end
      end
      CELL_SPOTS.each do |x, y|
        told = BAR_COLORS.fetch((2 * 4) + BAR_TILES.fetch(3).fetch((y * 8) + 7 - x))
        assert_equal told, shown.pixel((TOLD_COLUMN * 8) + x, y), "the cell written later at (#{x}, #{y})"
      end
      assert_equal ARENA_COLORS.fetch(5), shown.pixel(5, BAR_ROWS), "the arena under the bar's rows"
    end
  end

  # A bar cell's see-through pixels show what is behind it, whichever bank it is drawn from: the
  # backdrop where the arena's cell is empty, the arena where it has one. A bank whose list starts
  # partway into a shared set keeps its see-through pixels see-through.
  def test_the_bars_see_through_pixels_show_what_is_behind_in_every_bank
    Dir.mktmpdir do |folder|
      shown = game_player.run(stage(bar_original(folder)), frames: 40).screen

      [0, 9].each do |column|
        assert_equal 0, shown.pixel((column * 8) + SEE_THROUGH_X, 0), "the backdrop through the bar's cell #{column}"
      end
      [17, 26].each do |column|
        arena = ARENA_COLORS.fetch(((column % ARENA_SETS) * 15) + SEE_THROUGH_X)
        assert_equal arena, shown.pixel((column * 8) + SEE_THROUGH_X, 0), "the arena through the bar's cell #{column}"
      end
      [1, 9].each do |column|
        arena = ARENA_COLORS.fetch(((column % ARENA_SETS) * 15) + SEE_THROUGH_X)
        assert_equal arena, shown.pixel((column * 8) + SEE_THROUGH_X, 8), "the arena through the bar's cell #{column} of row 1"
      end
      mirrored_x = 7 - SEE_THROUGH_X
      arena = ARENA_COLORS.fetch(((TOLD_COLUMN % ARENA_SETS) * 15) + mirrored_x)
      assert_equal arena, shown.pixel((TOLD_COLUMN * 8) + mirrored_x, 0), "the arena through the cell written later"
    end
  end

  # A BAR SHOWN ALONE ABOVE ITS ROW (`alone: true`), as a Super Nintendo game shows its bar on the
  # rows above its split: over an arena scrolled a pixel each pass, its see-through pixels show the
  # backdrop in every bank, never the arena, and the arena still shows from the row down.
  def test_a_bar_shown_alone_shows_the_backdrop_through_its_see_through_pixels
    Dir.mktmpdir do |folder|
      shown = game_player.run(stage(bar_original(folder), alone: true, scrolled: true), frames: 40).screen

      [0, 9, 17, 26].each do |column|
        [0, 8, BAR_ROWS - 1].each do |y|
          assert_equal BACKDROP, shown.pixel((column * 8) + SEE_THROUGH_X, y), "the backdrop through the bar's cell #{column} at row #{y}"
        end
        assert_equal bar_color(column, 0, 0), shown.pixel(column * 8, 0), "the bar's cell #{column}"
      end
      [5, 100, 200].each do |x|
        assert_includes ARENA_COLORS, shown.pixel(x, BAR_ROWS), "the scrolled arena under the bar's rows at #{x}"
      end
    end
  end

  # The same stage scrolled, without the setting: the arena shows through the bar, as before.
  def test_a_bar_not_shown_alone_shows_the_scrolled_arena_through_its_see_through_pixels
    Dir.mktmpdir do |folder|
      shown = game_player.run(stage(bar_original(folder), scrolled: true), frames: 40).screen

      [17, 26].each do |column|
        assert_includes ARENA_COLORS, shown.pixel((column * 8) + SEE_THROUGH_X, 8), "the arena through the bar's cell #{column}"
      end
    end
  end

  # The colour the bar shows at (+x+, +y+) of the screen, as drawn: nil where it is see-through.
  private def bar_pixel(x, y)
    word = BAR_WORDS.fetch(((y / 8) * 32) + (x / 8))
    place = BAR_TILES.fetch(word & 0x3FF).fetch(((y % 8) * 8) + (x % 8))
    place.zero? ? nil : BAR_COLORS.fetch((((word >> 10) & 7) * 4) + place)
  end

  # A BAR SHOWN ALONE WITHOUT SPRITES (`alone: :without_sprites`), as a Super Nintendo game shows its
  # bar with only that layer on the lines above its split: a sprite climbing across the row is hidden
  # above it, the bar's own pixels and the backdrop showing there, and shown from the row down.
  def test_a_bar_shown_alone_without_sprites_hides_a_sprite_above_its_row
    Dir.mktmpdir do |folder|
      shown = game_player.run(stage(bar_original(folder), alone: :without_sprites, crossing: true), frames: CROSSING_FRAMES).screen

      (CROSSING_X...(CROSSING_X + CROSSING_SIDE)).each do |x|
        CROSSING_ROWS_ABOVE.each do |y|
          assert_equal bar_pixel(x, y) || BACKDROP, shown.pixel(x, y), "the bar over the hidden sprite at (#{x}, #{y})"
        end
        CROSSING_ROWS_BELOW.each { |y| assert_equal WHITE, shown.pixel(x, y), "the sprite under the bar's row at (#{x}, #{y})" }
      end
    end
  end

  # Shown alone with its sprites (`alone: true`), the same sprite shows through the bar's see-through
  # pixels above the row (the stack puts the bar in front of it).
  def test_a_bar_shown_alone_with_sprites_shows_a_sprite_through_it_above_its_row
    Dir.mktmpdir do |folder|
      shown = game_player.run(stage(bar_original(folder), alone: true, crossing: true), frames: CROSSING_FRAMES).screen

      (CROSSING_X...(CROSSING_X + CROSSING_SIDE)).each do |x|
        CROSSING_ROWS_ABOVE.each do |y|
          assert_equal bar_pixel(x, y) || WHITE, shown.pixel(x, y), "the bar over the sprite at (#{x}, #{y})"
        end
        CROSSING_ROWS_BELOW.each { |y| assert_equal WHITE, shown.pixel(x, y), "the sprite under the bar's row at (#{x}, #{y})" }
      end
    end
  end
end
