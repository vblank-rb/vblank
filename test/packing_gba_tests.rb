# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original"

# THE GAME BOY ADVANCE BIOS'S FORMATS AS BUILDING BLOCKS OF AN UNPACKING ROUTINE
# (Original::Packing::GBA): `copy.unpack_lz77` and `copy.unpack_rle`, played where an unpacking
# routine runs (CopyReaderTests says where, and which files include this). Their answer key is
# BiosCompress, the packer the GBA lowering uses.
module PackingGBATests
  include MadeUpOriginal

  # The made-up original's routine (MadeUpOriginal#unpacked_pack), its slots read back from what it
  # wrote.
  def test_the_routine_unpacks_an_lz77_block_and_an_rle_block_into_one_pack
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(VBlank::Builder.new, folder).unpacking
      played = game_player.run(unpacking.program, frames: 8)

      assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                   unpacking.slot_bytes_in(played))
    end
  end

  # A longer block, with runs and repeats both, packed each way and unpacked by the routine back to
  # its bytes.
  def test_each_decompressor_gives_back_what_bios_compress_packed
    raw = ((0...90).map { |at| (at * 7) & 0x3F } + [0] * 40 + (0...90).map { |at| (at * 7) & 0x3F } + [5] * 3).pack("C*")
    copy = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize) +
           Packer.with_bios_header(Packer.rle(raw), Packer::TYPE_RLE, raw.bytesize)
    rle_at = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize).bytesize
    Dir.mktmpdir do |folder|
      from = copy_of(folder, copy)
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :by_lz77, count: raw.bytesize, width: :byte, signed: false
        slots.numbers :by_rle, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy do |bytes, pack|
          bytes.unpack_lz77 at: 0, into: pack[:by_lz77]
          bytes.unpack_rle at: rle_at, into: pack[:by_rle]
        end
      end.unpacking

      assert_equal({ by_lz77: raw, by_rle: raw }, unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 8)))
    end
  end
end
