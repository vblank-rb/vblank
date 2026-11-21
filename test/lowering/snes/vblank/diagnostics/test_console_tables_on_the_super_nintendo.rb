# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port reads its original's tables off the cartridge file, which has no build record: the video
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

  # The game read with its build record, and a probe over its bare file, both frames frames in.
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

  # The two sizes are read off the cartridge (OBSEL), so a bare file needs none given: VBlank's
  # build sets OBSEL's sizes 0, and its box is 8 by 8.
  def test_sprite_boxes_read_the_sizes_the_game_set
    with_recorded_and_bare do |_recorded, bare|
      assert_equal [[40, 60, 8, 8]], bare.sprite_boxes.map { |box| [box.x, box.y, box.width, box.height] }
    end
  end

  # A game that sets OBSEL's sizes 3, 16 by 16 and 32 by 32 (fullsnes, "SNES PPU Sprites (OBJs)"),
  # with one small sprite at (40, 60) and one large at (100, 60), its size bit set in the upper
  # table. Made by hand, a bare file as a port's original is, since VBlank's own build sets sizes 0.
  def test_sprite_boxes_are_read_at_both_sizes_the_game_set
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "sizes.sfc")
      VBlank::Cartridge::SNESROM.new([TWO_SPRITE_SIZES.pack("C*")], title: "SIZES", vectors: { reset: 0x8000 }).write(path)
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(3)
        boxes = probe.reader.sprite_boxes.first(2).map { |box| [box.x, box.y, box.width, box.height] }

        assert_equal [[40, 60, 16, 16], [100, 60, 32, 32]], boxes
        assert_equal [[40, 60, 8, 8], [100, 60, 16, 16]],
                     probe.reader.sprite_boxes(sizes: SPRITE_SIZES).first(2).map { |box| [box.x, box.y, box.width, box.height] },
                     "sizes: given are used over the ones the game set"
      end
    end
  end

  # The 65816's instructions for that game, each instruction's bytes from its opcode table: the
  # screen off, OBSEL set, two entries of the sprite table and the upper table's first byte
  # written, the screen on, and round for ever.
  TWO_SPRITE_SIZES = [
    0x78, 0x18, 0xFB, #  SEI; CLC; XCE    native mode
    0xA9, 0x80, 0x8D, 0x00, 0x21, #  LDA #$80; STA $2100   INIDISP: screen off
    0xA9, 0x60, 0x8D, 0x01, 0x21, #  LDA #$60; STA $2101   OBSEL: sizes 3
    0x9C, 0x02, 0x21, 0x9C, 0x03, 0x21, #  STZ $2102; STZ $2103   OAMADD: entry 0
    *[40, 60, 0, 0, 100, 60, 0, 0].flat_map { |byte| [0xA9, byte, 0x8D, 0x04, 0x21] }, # LDA #byte; STA $2104
    0x9C, 0x02, 0x21, 0xA9, 0x01, 0x8D, 0x03, 0x21, #  STZ $2102; LDA #$01; STA $2103   OAMADD: the upper table
    0xA9, 0x08, 0x8D, 0x04, 0x21, #  LDA #$08; STA $2104   entry 1 large
    0xA9, 0x00, 0x8D, 0x04, 0x21, #  LDA #$00; STA $2104
    0xA9, 0x0F, 0x8D, 0x00, 0x21, #  LDA #$0F; STA $2100   INIDISP: screen on, full brightness
    0x80, 0xFE #                       BRA -2
  ].freeze
end
