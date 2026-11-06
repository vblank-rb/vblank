# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_data_packs"

# THE MADE-UP PORT A SHELL IS TESTED WITH, and the pack its all-in-one build makes, shared by the
# shell tests of each runtime (test/lowering/ruby/vblank/live/test_shell.rb, and the web page's and
# the desktop program's). The shell holds none of MadeUpOriginal's data; the answer key is the
# same game built all-in-one from the same copy.
module ShellTests
  include MadeUpOriginal

  # The pack the all-in-one build makes from the copy: every slot as the routine unpacks it.
  ALL_IN_ONE_PACK = Ractor.make_shareable(
    VBlank::Original::Pack.holding({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                                   sha1: SHA1, build_version: "1").to_bytes
  )

  # The made-up port: the colours copied as they are, the tiles and the heights unpacked by its
  # routine, laid out as a background with a marker placed by the heights. +version+ is the build
  # the pack names.
  private def port(from, version: "1")
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: version) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :wall_b, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        draw_rect_at heights[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 15
      end
    end
  end

  # The copy, written to a file in +folder+.
  private def copy_at(folder)
    File.join(folder, "made_up.gba").tap { |path| File.binwrite(path, COPY) }
  end

  # A file of the copy's size that is no release of the original.
  private def wrong_copy_at(folder)
    File.join(folder, "wrong.gba").tap { |path| File.binwrite(path, COPY.reverse) }
  end

  # A file no release is the size of.
  private def short_copy_at(folder)
    File.join(folder, "short.gba").tap { |path| File.binwrite(path, COPY.byteslice(0, 100)) }
  end
end
