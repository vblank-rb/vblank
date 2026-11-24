# frozen_string_literal: true

require "test_helper"

# The cartridge writes the console's sprite table 16 or 32 bits at a time. The table ignores a
# write of one byte (GBATEK, "LCD OBJ - OAM Attributes"), so a build that stored sprite numbers
# a byte at a time would leave the table as it was and the sprites would never show. Each
# sprite's three numbers are checked here, read out of the table itself, next to a second
# sprite so a smear into the neighbour shows up too.
class TestSpriteTableWritesCartridge < Minitest::Test
  # Two sprites of different pictures, one still and one the game moves every frame, so both the
  # first write and the per-frame write are played.
  private def two_sprites
    VBlank.game("OAMWRITE", consoles: %i[gba]) do
      screen :tiled
      image :red_square, "#" => :red do "########\n" * 8 end
      image :blue_square, "#" => :blue do "########\n" * 8 end
      sprite :red_square, at: [37, 53]
      mover = sprite :blue_square, at: [101, 70]
      game_loop { mover.x += 1 }
    end
  end

  # The three numbers of an entry that carry the sprite's own values.
  Entry = Data.define(:x, :y, :tile)

  # Each entry of the table is four 16-bit numbers.
  private def entries(table)
    table.unpack("v*").each_slice(4).map { |down, across, tile, _| Entry.new(x: across & 0x1FF, y: down & 0xFF, tile: tile & 0x3FF) }
  end

  def test_both_sprites_land_whole_in_the_sprite_table
    console = assert_emulator_loads_rom(assemble_rom(two_sprites.program, name: "OAMWRITE"), frames: 10)
    shown = entries(console.sprite_table)

    red = shown.find { |entry| entry.x == 37 && entry.y == 53 }
    blue = shown.find { |entry| entry.y == 70 && entry.x > 101 }

    refute_nil red, "the still sprite's across and down must both be in the table"
    refute_nil blue, "the moving sprite's across and down must both be in the table"
    refute_equal red.tile, blue.tile, "each sprite keeps its own picture number"
  end
end
