# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port reads its original's tables off the cartridge file, which has no build record: the video
# memory, the colours, the sprite table and the sound registers, as bytes, and the sprite table as
# boxes. The cartridge is a small game built here and written to a file, a white box on a blue field
# at (40, 60); the same cartridge read with its build record is the answer key for where the box is.
class TestConsoleTables < Minitest::Test
  # Long enough for the game to start and its sprite table to reach the console.
  FRAMES = 30

  # +turned+ turns the box a little on every pass, so the console draws it in a box twice its size.
  private def boxed_game(turned: false)
    VBlank.build("BOXED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      box = sprite :box, at: [40, 60]
      game_loop { box.turn(3) if turned }
    end
  end

  # The game read with its build record, and a probe over its bare file, both FRAMES frames in.
  private def with_recorded_and_bare(turned: false)
    Dir.mktmpdir("cartridges") do |folder|
      built = boxed_game(turned: turned)
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
      assert_equal recorded.video_ram, bare.video_ram, "video_ram"
      assert_equal recorded.color_ram, bare.color_ram, "color_ram"
      assert_equal recorded.sprite_table, bare.sprite_table, "sprite_table"
      assert_equal recorded.sound_registers, bare.sound_registers, "sound_registers"
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

  # A turned box is drawn in a box twice its size with the picture in its middle, so its box off the
  # bare file is 16 by 16, standing half the picture up and to the left of where the game put it.
  def test_a_turned_sprite_s_box_is_the_double_size_box_it_is_drawn_in
    with_recorded_and_bare(turned: true) do |_recorded, bare|
      assert_equal [[36, 56, 16, 16]], bare.sprite_boxes.map { |box| [box.x, box.y, box.width, box.height] }
    end
  end

  # The Advance's sound is all in its registers, so the sound chip's own memory is refused, naming
  # what to read instead.
  def test_the_sound_ram_is_refused_on_the_advance
    with_recorded_and_bare do |_recorded, bare|
      message = assert_raises(ArgumentError) { bare.sound_ram }.message

      assert_match "Game Boy Advance", message
      assert_match "sound_registers", message
    end
  end
end
