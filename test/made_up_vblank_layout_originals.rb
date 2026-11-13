# frozen_string_literal: true

require "digest"
require "tmpdir"
require "pack_background_tests"

# MADE-UP ORIGINALS OF PLATFORMS WHOSE LAYOUT VBLANK DOES NOT READ: a PlayStation original, a computer
# original and one that names a platform VBlank does not list (an arcade board). A slot of such an
# original is in VBlank's own layout (Console::VBLANK_FORMATS): colours of fifteen bits, low byte
# first; tiles a byte a pixel, each a place in its bank; numbers low byte first. So the port's
# unpacking routine writes each colour, tile and number into that layout from however its original
# keeps them, and needs no `layout:` line.
#
# Each original here is made up, and keeps its data in a way of its own that no console has: each
# colour as three bytes, a channel each, of +depth+ bits (the PlayStation's five, a computer's six
# as its video card takes them, an arcade board's eight); tiles of sixteen colours two pixels a byte,
# the left in the high half; a map of two bytes a cell, the tile and then its bank in bit 0,
# mirrored in bit 1 and upside down in bit 2; numbers of two bytes high byte first, and of one byte.
#
# THE ANSWER KEY is the same screen drawn by the game itself (#vblank_layout_drawn_by_hand): the
# colours, tiles, cells and numbers here, never read back through VBlank's readers.
module MadeUpVBlankLayoutOriginals
  include PackBackgroundGames

  # One made-up original: the platform it names, and how many bits a channel of its colours has.
  MadeUpPlatform = Data.define(:platform, :depth)
  ORIGINALS = [MadeUpPlatform.new(platform: :ps1, depth: 5), MadeUpPlatform.new(platform: :pc, depth: 6),
               MadeUpPlatform.new(platform: :arcade, depth: 8)].freeze

  # Two banks of sixteen colours (PackBackgroundGames::BANKS), each a colour every console shows exactly.
  PALETTE = BANKS.flatten.freeze
  # The map, four cells across: the tile, its bank, and its turns.
  CELLS = [[1, 0, false, false], [2, 1, true, false], [3, 0, false, true], [1, 1, true, true],
           [0, 0, false, false], [3, 1, false, false], [2, 0, true, true], [1, 0, false, false]].freeze
  ACROSS = 4
  # Where the sprite stands each frame: across, the low byte of a number whose high byte is not 0, so
  # a number read in the wrong byte order puts it elsewhere; and down, a byte.
  ACROSSES = [10, 30, 50, 70, 90, 110, 130, 150].each_with_index.map { |x, at| x | ((at + 1) << 8) }.freeze
  DOWNS = [60, 64, 70, 72, 80, 84, 90, 96].freeze

  COLORS_AT = 0x10
  CELLS_AT = 0x80
  ACROSSES_AT = 0x90
  DOWNS_AT = 0xA0
  TILES_AT = 0xC0
  TILE_BYTES = 32

  VBlank::Testing::InRactors.share_constants(self)

  # A channel of five bits widened to +depth+ bits, its bits repeated, so its +depth+ - 5 lowest bits
  # dropped give it back.
  def self.widen_channel(channel, depth) = depth == 5 ? channel : (channel << (depth - 5)) | (channel >> (10 - depth))

  # +made_up+'s copy, written into +folder+, as the Original::Game a port names.
  private def vblank_layout_original(folder, made_up)
    copy = vblank_layout_copy(made_up)
    path = File.join(folder, "made_up_#{made_up.platform}.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: made_up.platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  private def vblank_layout_copy(made_up)
    copy = "\0".b * (TILES_AT + (PLACES.length * TILE_BYTES))
    channels = PALETTE.flat_map { |color| [color & 31, (color >> 5) & 31, (color >> 10) & 31] }
    copy[COLORS_AT, channels.length] = channels.map { |channel| MadeUpVBlankLayoutOriginals.widen_channel(channel, made_up.depth) }.pack("C*")
    cells = CELLS.flat_map { |tile, bank, mirrored, upside_down| [tile, bank | (mirrored ? 2 : 0) | (upside_down ? 4 : 0)] }
    copy[CELLS_AT, cells.length] = cells.pack("C*")
    copy[ACROSSES_AT, ACROSSES.length * 2] = ACROSSES.pack("n*")
    copy[DOWNS_AT, DOWNS.length] = DOWNS.pack("C*")
    tiles = PLACES.map { |places| places.each_slice(2).map { |left, right| (left << 4) | right }.pack("C*") }.join
    copy[TILES_AT, tiles.bytesize] = tiles
    copy
  end

  # A game showing +from+'s screen through its data pack, with no layout: line: the unpacking routine
  # writes each colour (`write_color`), tile and number in VBlank's layout. A background of the
  # original's tiles, map and colours, and a sprite of two of its tiles in its second bank, moved by
  # its numbers. Hands back the program and the pack file the build made (nil with the pack left out).
  private def vblank_layout_game_and_file(from, made_up, options: VBlank::Cartridge::Options.new)
    tile_count = PLACES.length
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.colors :palette, count: PALETTE.length
        slots.tiles :video, count: tile_count, colors: 16
        slots.map_cells :map, count: CELLS.length
        slots.numbers :acrosses, count: ACROSSES.length, width: :half, signed: false
        slots.numbers :downs, at: DOWNS_AT, count: DOWNS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, filled|
          repeat(PALETTE.length) do |at|
            filled[:palette].write_color(at, red: copy.byte(COLORS_AT + (at * 3)), green: copy.byte(COLORS_AT + (at * 3) + 1),
                                             blue: copy.byte(COLORS_AT + (at * 3) + 2), bits: made_up.depth)
          end
          repeat(tile_count * TILE_BYTES) do |at|
            two = copy.byte(TILES_AT + at)
            filled[:video][at * 2] = two >> 4
            filled[:video][(at * 2) + 1] = two & 15
          end
          repeat(CELLS.length) do |at|
            turns = copy.byte(CELLS_AT + (at * 2) + 1)
            filled[:map].write_cell(at, tile: copy.byte(CELLS_AT + (at * 2)), bank: turns & 1, mirrored: turns >> 1,
                                        upside_down: turns >> 2)
          end
          repeat(ACROSSES.length) { |at| filled[:acrosses][at] = copy.half(ACROSSES_AT + (at * 2), big_endian: true) }
        end
      end
      background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS
      image :hero, width: 16, height: 8, colors: pack[:palette].bank(1), places: pack[:video].tiles(1, across: 2)
      MadeUpVBlankLayoutOriginals.emit_hero_loop(self, table(:acrosses, pack[:acrosses]), table(:downs, pack[:downs]))
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE ANSWER KEY: the same screen, its colours, tiles, cells and numbers written in the game.
  private def vblank_layout_drawn_by_hand
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      BANKS.each_with_index { |bank, at| colors :"bank_#{at}", bank }
      pictures = {}
      drawn = CELLS.map do |tile, bank, mirrored, upside_down|
        places = PLACES.fetch(tile)
        next nil if places.all?(&:zero?)

        rows = places.each_slice(8).to_a
        rows = rows.map(&:reverse) if mirrored
        rows = rows.reverse if upside_down
        name = :"cell #{pictures.length}"
        image name, width: 8, height: 8, places: rows.flatten, colors: :"bank_#{bank}"
        pictures[name] = name
      end
      tiles :by_hand, pictures
      background :world, tiles: :by_hand, map: drawn.each_slice(ACROSS).to_a
      hero = PLACES.fetch(1).each_slice(8).zip(PLACES.fetch(2).each_slice(8)).flat_map { |left, right| left + right }
      image :hero, width: 16, height: 8, colors: :bank_1, places: hero
      MadeUpVBlankLayoutOriginals.emit_hero_loop(self, table(:acrosses, ACROSSES, width: :half, signed: false),
                                                 table(:downs, DOWNS, width: :byte, signed: false))
    end
    b.finalize_program
    b.program
  end

  # The sprite, moved each frame to the next number of each table.
  def self.emit_hero_loop(builder, acrosses, downs)
    builder.instance_eval do
      hero = sprite :hero, at: [0, 60]
      step = var :step, 0
      game_loop do
        wait_vblank
        hero.move_to acrosses[step] & 0xFF, downs[step]
        step.store!((step + 1) & 7)
      end
    end
  end
end
