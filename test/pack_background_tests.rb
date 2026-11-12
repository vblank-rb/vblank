# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "pack_at_start_tests"

# MADE-UP ORIGINALS WHOSE SCREEN IS A BACKGROUND OF THEIR OWN TILES, MAP AND COLOURS, and a game
# that shows it through a data pack (Builder::PackBackgrounds). The answer key is the made-up data
# itself: each cell of the map names a tile, a bank of colours and a turn, written here from each
# console's hardware and not from VBlank's readers.
module PackBackgroundGames
  # Four colours a tile, so the Game Boy Color can show every tile here too.
  PLACES = [
    Array.new(64, 0),                                                     # tile 0: draws nothing
    (0...64).map { |at| ((at % 8) + (2 * (at / 8))) % 4 },                # tile 1: no row reads the same both ways
    (0...64).map { |at| (at / 8).even? ? 1 + ((at % 8) / 3) : 3 },        # tile 2: no column reads the same up and down
    (0...64).map { |at| at % 8 < 4 ? 2 : 1 }                              # tile 3
  ].freeze
  # Two banks of sixteen colours: each place a colour of its own in each bank, every one a colour
  # the Genesis shows exactly.
  BANKS = [MadeUpOriginalLayouts::PALETTE, MadeUpOriginalLayouts::PALETTE.rotate(7)].freeze
  OTHER = MadeUpOriginalLayouts::PALETTE.rotate(3)
  LATER = MadeUpOriginalLayouts::PALETTE.rotate(5)

  # The Advance keeps a tile two pixels a byte, the left one in the low half.
  LOW_HALF_FIRST = ->(places) { places.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*") }

  # A cell of the Advance's map: tile in bits 0 to 9, mirrored 10, upside down 11, bank 12 to 15.
  ADVANCE_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (mirrored ? 1 << 10 : 0) | (upside_down ? 1 << 11 : 0) | (bank << 12)
  end
  # A cell of the Super Nintendo's: tile 0 to 9, bank 10 to 12, priority 13, mirrored 14, upside down 15.
  SNES_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (bank << 10) | (1 << 13) | (mirrored ? 1 << 14 : 0) | (upside_down ? 1 << 15 : 0)
  end

  # A cell of the Genesis's: tile 0 to 10, mirrored 11, upside down 12, bank 13 and 14, priority 15.
  GENESIS_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (mirrored ? 1 << 11 : 0) | (upside_down ? 1 << 12 : 0) | (bank << 13) | (1 << 15)
  end
  # The Genesis keeps its colours in nine bits, high byte first; BANKS are levels it shows exactly.
  GENESIS_COLORS = lambda do |levels|
    levels.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
  end

  TILES_AT = 0x100
  COLORS_AT = 0x40
  MAP_AT = 0x20

  # A made-up original for +platform+: +tiles+ (bytes) at TILES_AT, the two banks at COLORS_AT and
  # +words+, the map, at MAP_AT.
  private def original(folder, platform, tiles, words)
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    genesis = platform == :genesis
    levels = MadeUpOriginalLayouts::LEVELS
    copy[COLORS_AT, 64] = genesis ? GENESIS_COLORS.(levels + levels.rotate(7)) : BANKS.flatten.pack("v*")
    copy[MAP_AT, words.length * 2] = words.pack(genesis ? "n*" : "v*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing one background from the pack, +across+ cells to a row, each +cell+ pixels
  # square, built as +options+ say. Hands back the program and the pack file the build made (nil
  # for a build that leaves its pack out).
  private def pack_game_and_file(from, tile_count, words, across:, cell:, colors: 16, options: VBlank::Cartridge::Options.new, &more)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: tile_count, colors: colors
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: across, cell: cell
      if more
        instance_exec(world, &more)
      else
        game_loop { wait_vblank }
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def pack_game(...) = pack_game_and_file(...).first

  # The Advance's tiles of PLACES, as its cartridge keeps them.
  private def advance_tiles = PLACES.map(&LOW_HALF_FIRST).join

  # A GAME BOY COLOR ORIGINAL, WHOSE MAP IS TWO MAPS: a byte a cell naming the tile, and a byte a
  # cell of attributes, written here from the Color's hardware: the bank of four colours in bits 0
  # to 2, the bank of video memory in bit 3, mirrored in bit 5, upside down in bit 6, and the
  # priority in bit 7, which no background reads. Each bank of video memory holds COLOR_BANK_TILES
  # tiles, bank 1's other than bank 0's, and the colours are eight banks of four. A bank is more
  # than 256 tiles, as the Color's 384 are, so a tile of bank 1 needs both bytes of a cell's tile;
  # bank 0's first four tiles are PLACES and the rest draw nothing.
  COLOR_BANK_TILES = 300
  COLOR_VIDEO = [*PLACES, *Array.new(COLOR_BANK_TILES - PLACES.length, PLACES[0]),
                 PLACES[0], PLACES[2], PLACES[3], PLACES[1]].freeze
  # Each cell: its tile in its bank of video memory, and its attribute byte.
  COLOR_CELLS = [[1, 0x00], [1, 0x21], [2, 0x4A], [3, 0x6F], [0, 0x00], [2, 0x83], [1, 0x0D], [3, 0x24]].freeze
  COLOR_ACROSS = 4
  COLOR_TILE_MAP_AT = 0x20
  COLOR_ATTRIBUTES_AT = 0x30
  COLOR_BANK_SIZE = 4
  COLOR_PALETTE = BANKS.flatten.freeze
  COLOR_WALK_STEPS = 5

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # The made-up Color original: COLOR_CELLS's two maps, the colours at COLORS_AT and the video at
  # TILES_AT, bank 0's tiles then bank 1's.
  private def color_original(folder)
    copy = "\0".b * (TILES_AT + (COLOR_VIDEO.length * 16))
    copy[COLOR_TILE_MAP_AT, COLOR_CELLS.length] = COLOR_CELLS.map(&:first).pack("C*")
    copy[COLOR_ATTRIBUTES_AT, COLOR_CELLS.length] = COLOR_CELLS.map(&:last).pack("C*")
    copy[COLORS_AT, COLOR_PALETTE.length * 2] = COLOR_PALETTE.pack("v*")
    copy[TILES_AT, COLOR_VIDEO.length * 16] = COLOR_VIDEO.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    path = File.join(folder, "made_up_color.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the Color original's screen through the pack: its unpacking joins the two maps
  # into map cells of VBlank's own (Original::MapCell), as a port does, and the background reads
  # them. With +walked+, every bank of colours is walked up from black by its name, as a Color game
  # fades its screen in by walking all eight of its background palettes. Hands back the program and
  # the pack file the build made (nil for a build that leaves its pack out).
  private def color_cells_game_and_file(from, walked: false, options: VBlank::Cartridge::Options.new)
    cells = COLOR_CELLS.length
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: COLOR_VIDEO.length
        slots.colors :palette, at: COLORS_AT, count: COLOR_PALETTE.length
        slots.map_cells :map, count: cells
        slots.fill_from_copy do |copy, filled|
          repeat(cells) do |at|
            attributes = copy.byte(COLOR_ATTRIBUTES_AT + at)
            filled[:map].write_cell(at, tile: copy.byte(COLOR_TILE_MAP_AT + at) + (((attributes >> 3) & 1) * COLOR_BANK_TILES),
                                        bank: attributes & 7, mirrored: attributes >> 5, upside_down: attributes >> 6)
          end
        end
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: COLOR_ACROSS
      PackBackgroundGames.emit_color_game_loop(self, world, walked)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE ANSWER KEY: the same screen with each cell decoded here, from the Color's hardware, and
  # written in the game as a picture of 8x8 in its bank's colours, turned as the cell says.
  private def color_cells_drawn_by_hand(walked: false)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      COLOR_PALETTE.each_slice(COLOR_BANK_SIZE).with_index { |bank, at| colors :"palette_#{at}", bank }
      pictures = {}
      drawn = COLOR_CELLS.map do |tile, attributes|
        places = COLOR_VIDEO.fetch(tile + (attributes[3] * COLOR_BANK_TILES))
        next nil if places.all?(&:zero?)

        rows = places.each_slice(8).to_a
        rows = rows.map(&:reverse) if attributes[5] == 1
        rows = rows.reverse if attributes[6] == 1
        name = :"cell #{pictures.length}"
        image name, width: 8, height: 8, places: rows.flatten, colors: :"palette_#{attributes & 7}"
        pictures[name] = name
      end
      tiles :by_hand, pictures
      world = background :world, tiles: :by_hand, map: drawn.each_slice(COLOR_ACROSS).to_a
      # A background of the game's own is walked only by the banks its tiles are drawn from.
      used = COLOR_CELLS.map { |_, attributes| attributes & 7 }.uniq
      PackBackgroundGames.emit_color_game_loop(self, world, walked, banks: used)
    end
    b.finalize_program
    b.program
  end

  # The Color games' loop: one that only waits, or with +walked+ one that walks every bank of
  # colours (or of +banks+) up from black by its name, a step a pass.
  def self.emit_color_game_loop(builder, world, walked, banks: (0...(COLOR_PALETTE.length / COLOR_BANK_SIZE)).to_a)
    builder.instance_eval do
      next game_loop { wait_vblank } unless walked

      walks = banks.to_h { |at| [:"palette_#{at}", color_walk(:"palette_#{at}", from: :black, steps: COLOR_WALK_STEPS)] }
      step = var :step, 0
      game_loop do
        world.draw_with(walks, showing: step)
        wait_vblank
        step.store!(step + 1)
      end
    end
  end
end

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT: what the same games built with `pack_at_start:
# true` hold when written out, and what a map the build never read does. That each plays as its
# all-in-one build is the registry's (PackGames::Backgrounds, test/pack_games.rb).
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackBackgroundAtStartTests
  include PackBackgroundGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The game as the block writes it out (as C, JavaScript or Ruby) holds each tile's pixels in its
  # bank's colours when built all-in-one, so the search can find them, and none of them built
  # with its pack left out; nor the tiles' bytes or the banks' colours as the original keeps
  # them. A lowering's test file calls this.
  private def assert_background_written_without_the_originals_bytes(&write)
    cells = [[1, 0], [2, 1], [3, 0]]
    words = cells.map { |tile, bank| ADVANCE_CELL.(tile, bank: bank) }
    drawn = cells.map { |tile, bank| PLACES.fetch(tile).map { |place| place.zero? ? 0xFFFF : BANKS.fetch(bank).fetch(place) } }
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, advance_tiles, words)
      whole, = pack_game_and_file(from, 4, words, across: 3, cell: 8)
      left_out, = pack_game_and_file(from, 4, words, across: 3, cell: 8, options: LEFT_OUT)
      ways_holding_needles([["the background", whole, left_out, drawn]], &write)
      runs = number_runs_in(yield(left_out))
      [advance_tiles.bytes.last(96), BANKS.flatten, BANKS.flatten.pack("v*").bytes].each do |raw|
        assert_empty ways_holding(runs, raw), "the background built with its pack left out holds raw bytes #{raw.first(8)}..."
      end
    end
  end

  # A cell naming a tile past the slot, or a bank past the colours, is refused as the all-in-one
  # build is made. A build that leaves its pack out never reads the map, so the tile draws nothing
  # and the game plays on.
  def test_a_cell_naming_a_tile_past_the_slot_read_at_start_draws_nothing
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(9)]
    drawn = [ADVANCE_CELL.(1), ADVANCE_CELL.(0)]
    Dir.mktmpdir do |folder|
      whole, = pack_game_and_file(original(folder, :gba, advance_tiles, drawn), 4, drawn, across: 2, cell: 8)
      from = original(folder, :gba, advance_tiles, words)
      left_out, = pack_game_and_file(from, 4, words, across: 2, cell: 8, options: LEFT_OUT)
      slots = { video: advance_tiles, map: words.pack("v*"), palette: BANKS.flatten.pack("v*") }
      sha1 = Digest::SHA1.hexdigest(File.binread(File.join(folder, "made_up.bin")))
      file = VBlank::Original::Pack.holding(slots, sha1: sha1, build_version: "1").to_bytes

      assert_equal game_player.run(whole, frames: 2).screen.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end
end
