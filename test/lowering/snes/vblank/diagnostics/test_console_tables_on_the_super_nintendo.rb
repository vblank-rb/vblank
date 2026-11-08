# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A PORT READS ITS ORIGINAL'S TABLES OFF THE CARTRIDGE FILE, which has no build record: the video
# memory, the colours, the sprite table and the sound chip's registers, as bytes, and the sprite table
# as boxes. The cartridge is a small game built here and written to a file, a white box on a blue
# field at (40, 60); the same cartridge read with its build record is the answer key for where the
# box is.
class TestConsoleTablesOnTheSuperNintendo < Minitest::Test
  # Long enough for the game to start and its sprite table to reach the console.
  FRAMES = 30

  # The Super Nintendo's build sets its sprites to 8×8 and 16×16 (OBSEL).
  SPRITE_SIZES = Ractor.make_shareable([[8, 8], [16, 16]])

  private def boxed_game
    VBlank.build("BOXED", console: :snes, out: StringIO.new, err: StringIO.new) do
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
      path = File.join(folder, "boxed.sfc").tap { |file| built.write(file) }
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
      assert_equal 64 * 1024, bare.video_ram.bytesize
      assert_equal 512, bare.color_ram.bytesize
      assert_equal 128, bare.sound_registers.bytesize
      assert_equal recorded.video_ram, bare.video_ram, "video_ram"
      assert_equal recorded.color_ram, bare.color_ram, "color_ram"
      assert_equal recorded.sprite_table, bare.sprite_table, "sprite_table"
      assert_equal recorded.sound_registers, bare.sound_registers, "sound_registers"
    end
  end

  # An entry of the Super Nintendo's table is its across, then its down (the SNES OAM layout).
  def test_the_sprite_table_holds_the_box_where_the_build_placed_it
    with_recorded_and_bare do |recorded, bare|
      slot = bare.sprite_boxes(sizes: SPRITE_SIZES).first.slot

      assert_equal 544, bare.sprite_table.bytesize
      assert_equal [[40, 60]], recorded.sprites(:box).map { |row| [row.x, row.y] }
      assert_equal [40, 60], bare.sprite_table.byteslice(slot * 4, 2).bytes
      assert_equal [[40, 60, 8, 8]],
                   bare.sprite_boxes(sizes: SPRITE_SIZES).map { |box| [box.x, box.y, box.width, box.height] }
    end
  end

  def test_sprite_boxes_are_refused_without_the_sizes
    with_recorded_and_bare do |_recorded, bare|
      assert_match "sizes:", assert_raises(ArgumentError) { bare.sprite_boxes }.message
    end
  end
end
