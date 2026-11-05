# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A PORT READS ITS ORIGINAL'S TABLES OFF THE CARTRIDGE FILE, which has no build record: the video
# memory, the colours, the sprite table and the sound registers, as bytes, and the sprite table as
# boxes. The cartridge is a small game built here and written to a file, a white box on a blue field
# at (40, 60); the same cartridge read with its build record is the answer key for where the box is.
class TestConsoleTables < Minitest::Test
  # Long enough for the game to start and its sprite table to reach the console.
  FRAMES = 30

  private def boxed_game
    VBlank.build("BOXED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      sprite :box, at: [40, 60]
      game_loop {}
    end
  end

  # The game read with its build record, and a probe over its bare file, both FRAMES frames in.
  private def with_recorded_and_bare
    Dir.mktmpdir("cartridges") do |folder|
      built = boxed_game
      path = File.join(folder, "boxed.gba").tap { |file| built.write(file) }
      recorded = VBlank::Diagnostics::Verifier.new(built, frames: FRAMES)
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(FRAMES)
        yield recorded, probe.reader
      end
      recorded.close
    end
  end

  def test_the_tables_off_the_bare_file_are_the_tables_the_build_made
    with_recorded_and_bare do |recorded, bare|
      assert_equal 96 * 1024, bare.video_ram.bytesize
      assert_equal 1024, bare.color_ram.bytesize
      assert_equal 72, bare.sound_registers.bytesize
      %i[video_ram color_ram sprite_table sound_registers].each do |table|
        assert_equal recorded.public_send(table), bare.public_send(table), table
      end
    end
  end

  # An entry of the Advance's table is its down in the first byte and its across in the low nine
  # bits of the second two (GBATEK, OBJ Attributes).
  def test_the_sprite_table_holds_the_box_where_the_build_placed_it
    with_recorded_and_bare do |recorded, bare|
      slot = bare.sprite_boxes.first.slot
      entry = bare.sprite_table.byteslice(slot * 8, 8)

      assert_equal 1024, bare.sprite_table.bytesize
      assert_equal [[40, 60]], recorded.sprites(:box).map { |row| [row.x, row.y] }
      assert_equal [60, 40], [entry.getbyte(0), entry.byteslice(2, 2).unpack1("v") & 0x1FF]
      assert_equal [[40, 60, 8, 8]], bare.sprite_boxes.map { |box| [box.x, box.y, box.width, box.height] }
    end
  end
end
