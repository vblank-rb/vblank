# frozen_string_literal: true

require_relative "test_helper"
require "weakref"

class TestCore < Minitest::Test
  # Native mode, the screen off, colour 0 set to pure red ($001F), $1234 stored in work RAM at
  # $0100, $A5 in video RAM's first word and $42 in the sprite table's first byte, the screen on
  # at full brightness, and round for ever. Each instruction's bytes are from the 65816's opcode
  # table.
  RED_BACKDROP = [
    0x78,             # SEI
    0x18,             # CLC
    0xFB,             # XCE          native mode
    0xA9, 0x80,       # LDA #$80
    0x8D, 0x00, 0x21, # STA $2100    INIDISP: screen off
    0x9C, 0x21, 0x21, # STZ $2121    CGADD: colour 0
    0xA9, 0x1F,       # LDA #$1F
    0x8D, 0x22, 0x21, # STA $2122    CGDATA low: red 31
    0x9C, 0x22, 0x21, # STZ $2122    CGDATA high
    0xA9, 0x34,       # LDA #$34
    0x8D, 0x00, 0x01, # STA $0100
    0xA9, 0x12,       # LDA #$12
    0x8D, 0x01, 0x01, # STA $0101
    0x9C, 0x16, 0x21, # STZ $2116    VMADDL
    0x9C, 0x17, 0x21, # STZ $2117    VMADDH
    0xA9, 0xA5,       # LDA #$A5
    0x8D, 0x18, 0x21, # STA $2118    VMDATAL
    0x9C, 0x02, 0x21, # STZ $2102    OAMADDL
    0x9C, 0x03, 0x21, # STZ $2103    OAMADDH
    0xA9, 0x42,       # LDA #$42
    0x8D, 0x04, 0x21, # STA $2104    OAMDATA: held in a latch until the odd byte comes
    0x8D, 0x04, 0x21, # STA $2104    OAMDATA: both bytes written
    0xA9, 0x0F,       # LDA #$0F
    0x8D, 0x00, 0x21, # STA $2100    INIDISP: screen on, full brightness
    0x80, 0xFE        # BRA -2
  ].freeze

  # The cartridge goes round its last line for ever, so nearly all of a frame's 262 lines of 1364
  # clocks are spent at one address, once the count has started.
  def test_the_processors_time_is_counted_by_address
    assert_empty @core.take_processor_time, "the first ask starts the count"

    2.times { @core.run_frame }
    spent = @core.take_processor_time.values.max

    assert_in_delta 262 * 1364 * 2, spent, 262 * 1364 * 2 * 0.1
  end

  def setup
    @dir = Dir.mktmpdir
    @core = RubySNESEmulator::Core.new(HandMadeCartridge.write(@dir, RED_BACKDROP))
    3.times { @core.run_frame }
  end

  def teardown
    @core&.destroy
    FileUtils.rm_rf(@dir)
  end

  def test_the_picture_is_the_backdrop_colour
    assert_equal [256, 224], [@core.width, @core.height]
    assert_equal [0x001F], @core.colors.uniq
  end

  # The manifest bsnes's heuristics wrote from the header names the board: a LoROM cartridge with
  # no RAM is the plain LOROM board.
  def test_the_manifest_names_the_board_bsnes_took_the_cartridge_for
    assert_match(/^\s*board:\s*LOROM$/, @core.manifest)
    assert_equal "LOROM", @core.board
  end

  # Every one of the fifteen bits reaches the picture: no gamma curve or colour correction stands
  # between the colour memory and what the core hands over.
  def test_a_colour_reaches_the_picture_exactly
    colour = 0x6A65 # red 5, green 19, blue 26
    code = RED_BACKDROP.take(11) + [0xA9, colour & 0xFF, 0x8D, 0x22, 0x21, 0xA9, colour >> 8, 0x8D, 0x22, 0x21,
                                   0xA9, 0x0F, 0x8D, 0x00, 0x21, 0x80, 0xFE]
    core = RubySNESEmulator::Core.new(HandMadeCartridge.write(@dir, code))
    3.times { core.run_frame }
    assert_equal [colour], core.colors.uniq
  ensure
    core&.destroy
  end

  def test_work_ram_reads_what_the_cartridge_stored
    assert_equal 0x1234, @core.wram_read16(0x0100)
  end

  def test_colour_memory_reads_what_the_cartridge_wrote
    assert_equal 0x001F, @core.cgram.unpack1("v")
  end

  def test_video_ram_reads_what_the_cartridge_wrote
    assert_equal 0xA5, @core.vram.getbyte(0)
  end

  def test_the_sprite_table_reads_what_the_cartridge_wrote
    assert_equal 544, @core.oam.bytesize
    assert_equal 0x42, @core.oam.getbyte(0)
  end

  def test_the_registers_say_where_the_processor_is
    registers = @core.registers
    assert_includes 0x803B..0x803D, registers.fetch(:pc) & 0xFFFF
    refute registers.fetch(:e), "the cartridge put the processor in native mode"
  end

  def test_two_cores_are_two_consoles
    other = RubySNESEmulator::Core.new(HandMadeCartridge.write(Dir.mktmpdir, RED_BACKDROP.take(3) + [0x80, 0xFE]))
    other.run_frame
    refute_equal 0x1234, other.wram_read16(0x0100)
    assert_equal 0x1234, @core.wram_read16(0x0100)
  ensure
    other&.destroy
  end

  # A console after another has closed is opened from the copy the first one used, and shows
  # nothing of it: its work RAM, its colours and its video RAM are as a console's are out of the box.
  def test_a_console_made_after_another_closed_starts_clean
    @core.destroy
    @core = RubySNESEmulator::Core.new(HandMadeCartridge.write(@dir, RED_BACKDROP.take(3) + [0x80, 0xFE]))
    @core.run_frame

    refute_equal 0x1234, @core.wram_read16(0x0100)
    refute_equal 0x001F, @core.cgram.unpack1("v")
    refute_equal 0xA5, @core.vram.getbyte(0)
  end

  # A console nobody destroyed is collected by Ruby in the end, and its copy of the core is handed
  # out again. The cartridge it held must go with it. bsnes takes a cartridge still in the console
  # out as the next one goes in, and writes that cartridge's RAM to the save file of the next one:
  # the new console would start from a save it was never given.
  def test_a_console_left_without_destroy_hands_its_save_to_nobody
    @core.destroy
    @core = nil
    dropped = Thread.new { drop_console_with_save("\x5A".b * 2048) }.value
    3.times { GC.start(full_mark: true, immediate_sweep: true) }
    refute dropped.weakref_alive?, "the dropped console was collected, so its copy is free for the next"

    fresh = Dir.mktmpdir
    @core = RubySNESEmulator::Core.new(HandMadeCartridge.write(fresh, [0x80, 0xFE], **HandMadeCartridge::BATTERY),
                                       save_dir: fresh)
    refute_equal [0x5A], @core.save_ram.bytes.uniq, "the new console started from the dropped console's save"
  end

  # Opened on a thread of its own and let go of there: Ruby looks for what is still held on every
  # stack, and a word left on the test's own could keep the console from being collected. Hands
  # back a weak reference, which says whether the console is still alive without keeping it so.
  private def drop_console_with_save(bytes)
    dir = Dir.mktmpdir
    core = RubySNESEmulator::Core.new(HandMadeCartridge.write(dir, [0x80, 0xFE], **HandMadeCartridge::BATTERY),
                                      save_dir: dir)
    core.save_ram = bytes
    core.run_frame
    WeakRef.new(core)
  end
end
