# frozen_string_literal: true

require "digest"
require "tmpdir"
require "genesis_packing_answers"

# THE SEGA GENESIS'S FORMATS AS BUILDING BLOCKS OF AN UNPACKING ROUTINE (Original::Packing::Genesis):
# `copy.unpack_nemesis` for tiles and `copy.unpack_enigma` for plane maps, played where an
# unpacking routine runs (CopyReaderTests says where, and which files include this). Each block is
# made up, written by GenesisPackingAnswers, and its answer key is that module's decoder, written
# from the 68000 routine the games run.
module PackingGenesisTests
  # Three tiles of many colours, with runs of one colour long and short, so every kind of code is in
  # a block made from them.
  GENESIS_TILES = (0...96).map { |at| ((at * 7) % 5).zero? ? 0x11 : ((((at / 3) % 16) * 0x11) ^ ((at % 4).zero? ? 0x23 : 0)) }
                          .pack("C*").freeze

  # Bytes the copy holds between its blocks, as a ROM holds other data there.
  FILLER = ([0xA5] * 8).pack("C*").freeze

  # Every op of a map, both flips, and the base added to every cell.
  MAP = GenesisPackingAnswers.enigma_block(width: 11, flips: 3, counting: 0x10, repeating: 0x20) do |ops|
    ops.counting(3)
    ops.repeating(2)
    ops.same([0x55, true, false], 2)
    ops.counting_up([0x60, false, true], 3)
    ops.counting_down([0x70, true, true], 3)
    ops.each_spelt([[1, false, false], [2, true, false], [3, false, true]])
    ops.counting(2)
  end.freeze
  MAP_BASE = 0x2000
  MAP_CELLS = GenesisPackingAnswers.enigma_cells(MAP, base: MAP_BASE).freeze

  # The unpacking a data pack of +slots+ (a block given the pack's slots) builds from +bytes+, a
  # copy of a Genesis original.
  private def genesis_unpacking(bytes, &slots)
    Dir.mktmpdir do |folder|
      path = File.join(folder, "packed.bin")
      File.binwrite(path, bytes)
      copy = VBlank::Original::Copy.new(path: path, sha1: Digest::SHA1.hexdigest(bytes), release: "Test", platform: :genesis)
      VBlank::Builder.new.data_pack(from: copy, version: "1", &slots).unpacking
    end
  end

  # The map's slot, of +count+ cells, and the routine that fills it.
  private def map_slots(slots, count: MAP_CELLS.length)
    slots.numbers :map, count: count, width: :half, signed: false, layout: :genesis
    slots.fill_from_copy { |bytes, pack| bytes.unpack_enigma at: FILLER.bytesize, into: pack[:map], base: MAP_BASE }
  end

  # Two blocks of the same tiles into one slot, the second from byte 96: one plain, with every code
  # in its table, and one in XOR mode, with five codes and the other runs spelt out.
  def test_unpack_nemesis_gives_back_the_tiles
    plain = GenesisPackingAnswers.nemesis_block(GENESIS_TILES, xor: false)
    xored = GenesisPackingAnswers.nemesis_block(GENESIS_TILES, xor: true, listed: 5)
    xored_at = plain.bytesize + FILLER.bytesize
    copy = plain + FILLER + xored + FILLER
    unpacking = genesis_unpacking(copy) do |slots|
      slots.tiles :art, count: 6, layout: :genesis
      slots.fill_from_copy do |bytes, pack|
        bytes.unpack_nemesis at: 0, into: pack[:art]
        bytes.unpack_nemesis at: xored_at, into: pack[:art], start: 96
      end
    end
    played = unpacking.run_on(game_player, frames: 20)

    assert_equal GENESIS_TILES * 2,
                 GenesisPackingAnswers.nemesis_tiles(copy, 0) + GenesisPackingAnswers.nemesis_tiles(copy, xored_at),
                 "the answer key reads back the tiles the blocks were made from"
    assert_equal({ art: GENESIS_TILES * 2 }, unpacking.slot_bytes_in(played))
    assert_equal unpacking.byte_size, unpacking.bytes_done_in(played)
  end

  # Each cell is a word, high byte first, as a Genesis keeps one.
  def test_unpack_enigma_gives_back_the_cells
    unpacking = genesis_unpacking(FILLER + MAP + FILLER) { |slots| map_slots(slots) }
    played = unpacking.run_on(game_player, frames: 20)

    assert_equal 0x2010, MAP_CELLS[0], "the counting word with the base added"
    assert_equal 0x3055, MAP_CELLS[5], "a spelt cell flipped top to bottom"
    assert_equal 0x2860, MAP_CELLS[7], "a spelt cell flipped side to side"
    assert_equal({ map: MAP_CELLS.pack("n*") }, unpacking.slot_bytes_in(played))
    assert_equal unpacking.byte_size, unpacking.bytes_done_in(played)
  end
end
