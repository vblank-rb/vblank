# frozen_string_literal: true

require "test_helper"
require "console/genesis/vblank/builder/test_big_sprite_pictures_on_the_genesis"

# WHAT A SPRITE PICTURE COSTS THE GENESIS'S SPRITE TABLE. An entry of the table draws a piece up to 32×32,
# and the console shows 80 entries at once and 20 on a row of the screen, so a big picture is covered by
# as few pieces as it can be. These read the table the console drew from, in its video memory.
class TestGenesisSpritePieces < Minitest::Test
  Tiles = VBlank::IR::Backends::Genesis::Runtime::Tiles

  def test_two_big_pictures_and_ten_small_ones_take_few_entries
    entries = sprite_table_after(BigSpritePictureGames.big_game)

    assert_includes 12...40, entries.length, "a 112×72, a 64×64 and ten small pictures, in entries"
    assert_operator most_on_a_row(entries), :<, 20, "entries on the busiest row"
  end

  def test_a_mirrored_big_picture_takes_as_few_entries
    entries = sprite_table_after(BigSpritePictureGames.mirrored_game)

    assert_includes 12...40, entries.length
    assert_operator most_on_a_row(entries), :<, 20
  end

  private

  # Each entry of the sprite table, as the console walks it from row 0 by each row's link: [left, top,
  # width, height], on the screen, in pixels. The screen comes on some frames after power-on, and the
  # table holds one row off the screen until it does.
  def sprite_table_after(program, frames: 30)
    rom = VBlank::Console.for(:genesis).builder.cartridge_for(program, title: "PIECES")
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.gen") do |core|
      frames.times { core.run_frame }
      table = core.vram.byteslice(Tiles::SPRITES_AT, 80 * 8)
      entries = []
      row = 0
      loop do
        top, size_link, _tile, left = table.byteslice(row * 8, 8).unpack("n4")
        size = size_link >> 8
        entries << [(left & 0x1FF) - Tiles::SPRITE_ORIGIN, (top & 0x3FF) - Tiles::SPRITE_ORIGIN,
                    ((size >> 2) + 1) * 8, ((size & 3) + 1) * 8]
        row = size_link & 0x7F
        break if row.zero? || entries.length > 80
      end
      entries
    end
  end

  # The most entries any row of the screen crosses.
  def most_on_a_row(entries)
    (0...224).map { |y| entries.count { |_, top, _, height| y >= top && y < top + height } }.max
  end
end
