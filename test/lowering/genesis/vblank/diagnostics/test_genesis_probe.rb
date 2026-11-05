# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A PORT OPENS ITS ORIGINAL GENESIS CARTRIDGE IN A PROBE, steps it, reads its work RAM by address,
# and reads the console's tables off the file, which has no build record: the video memory, the
# colours, the sprite table, the FM chip's registers, the scroll memory and the video registers, as
# bytes, and the sprite table as boxes. The cartridge is a small game built here and written to a
# file, a white box on a blue field at (40, 60) and a count of its passes; the same cartridge read
# with its build record is the answer key for the count.
class TestGenesisProbe < Minitest::Test
  # Long enough for the game to start and its sprite table to reach the console.
  FRAMES = 30

  private def boxed_game
    VBlank.build("BOXED", console: :genesis, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 40 }
      sprite :box, at: [40, 60]
      ticks = var :ticks, 0
      game_loop { ticks += 1 }
    end
  end

  # The game read with its build record, a probe over its bare file, both FRAMES frames in, and
  # where the build put the count.
  private def with_recorded_and_bare
    Dir.mktmpdir("cartridges") do |folder|
      built = boxed_game
      path = File.join(folder, "boxed.md").tap { |file| built.write(file) }
      recorded = VBlank::Diagnostics::Verifier.new(built, frames: FRAMES, vars: built.var_addresses)
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(FRAMES)
        yield recorded, probe, built.var_addresses.fetch(:ticks)
      end
      recorded.close
    end
  end

  def test_a_genesis_cartridge_file_opens_steps_and_reads_its_work_ram
    with_recorded_and_bare do |recorded, probe, ticks|
      assert_operator recorded.var(:ticks), :>, 0
      assert_equal recorded.var(:ticks), probe.read(ticks, as: :s32)
      assert probe.reader.blue?(0, 0), "the field is up"
      assert probe.reader.white?(44, 64), "the box is up"
    end
  end

  def test_the_tables_off_the_bare_file_are_the_tables_the_build_made
    with_recorded_and_bare do |recorded, probe, _ticks|
      bare = probe.reader

      assert_equal 64 * 1024, bare.video_ram.bytesize
      assert_equal 128, bare.color_ram.bytesize
      assert_equal 512, bare.sound_registers.bytesize
      assert_equal 80, bare.scroll_ram.bytesize
      assert_equal 24, bare.video_registers.bytesize
      %i[video_ram color_ram sprite_table sound_registers scroll_ram video_registers].each do |table|
        assert_equal recorded.public_send(table), bare.public_send(table), table
      end
    end
  end

  # An entry of the Genesis's table is its down plus 128 in its first word and its across plus 128
  # in its last (the VDP's sprite attribute table), high byte first.
  def test_the_sprite_table_holds_the_box_where_the_build_placed_it
    with_recorded_and_bare do |_recorded, probe, _ticks|
      bare = probe.reader
      slot = bare.sprite_boxes.first.slot
      down, *, across = bare.sprite_table.byteslice(slot * 8, 8).unpack("nCCnn")

      assert_equal 80 * 8, bare.sprite_table.bytesize
      assert_equal [60 + 128, 40 + 128], [down, across]
      assert_equal [[40, 60, 8, 8]], bare.sprite_boxes.map { |box| [box.x, box.y, box.width, box.height] }
    end
  end

  def test_an_address_outside_work_ram_is_refused
    with_recorded_and_bare do |_recorded, probe, _ticks|
      assert_match "work RAM", assert_raises(ArgumentError) { probe.read(0x0100) }.message
    end
  end
end
