# frozen_string_literal: true

require_relative "test_helper"

class TestCore < Minitest::Test
  include HandMadeCartridge
  extend HandMadeCartridge

  # The video chip set up by hand: mode 5 with the screen on and 40 cells across, colour 0 of the
  # first list of colours set to a red of 2, a green of 4 and a blue of 6 (each of the console's
  # three bits of a colour channel), $1234 stored in work RAM at $FF0100 and $A5C3 in video RAM at
  # $8000, then round for ever. The colour is written in the console's own layout: 0000 BBB0 GGG0
  # RRR0. Video RAM at $8000 is where no map or tile the picture uses is.
  COLOR = 0x0C84

  CODE = [
    *move_word(0x8004, VDP_CONTROL),      # register 0: nothing special
    *move_word(0x8144, VDP_CONTROL),      # register 1: the screen on, mode 5
    *move_word(0x8700, VDP_CONTROL),      # register 7: the backdrop is colour 0
    *move_word(0x8C81, VDP_CONTROL),      # register 12: 40 cells across, 320 pixels
    *move_long(0xC0000000, VDP_CONTROL),  # write colour memory from colour 0
    *move_word(COLOR, VDP_DATA),
    *move_word(0x8F02, VDP_CONTROL),      # register 15: the address moves on by 2
    *move_long(0x40000002, VDP_CONTROL),  # write video RAM from address $8000
    *move_word(0xA5C3, VDP_DATA),
    *move_long(0x40000010, VDP_CONTROL),  # write vertical scroll memory from 0
    *move_word(0x0123, VDP_DATA),
    *move_word(0x1234, 0xFF0100),
    *LOOP
  ].freeze

  # Reads the first pad into $FF0102 for ever, with the pad's select line high: the console
  # hands over the buttons as bits that are 0 where a button is down.
  PAD_PORT_DATA = 0xA10003
  PAD_PORT_CONTROL = 0xA10009
  PAD_CODE = [
    *move_byte(0x40, PAD_PORT_CONTROL),
    *move_byte(0x40, PAD_PORT_DATA),
    *copy_byte(PAD_PORT_DATA, 0xFF0102),
    0x60, 0xEC # BRA.S back to the write of the select line
  ].freeze

  def setup
    @dir = Dir.mktmpdir
    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, CODE))
    3.times { @core.run_frame }
  end

  def teardown
    @core&.destroy
    FileUtils.rm_rf(@dir)
  end

  def test_the_picture_is_the_backdrop_colour
    assert_equal [320, 224], [@core.width, @core.height]
    assert_equal [0b110_100_010], @core.colors.uniq
  end

  def test_work_ram_reads_what_the_cartridge_stored_high_byte_first
    assert_equal 0x1234, @core.wram_read16(0xFF0100)
    assert_equal [0x12, 0x34], [@core.wram_read8(0x0100), @core.wram_read8(0x0101)]
    assert_equal "\x12\x34".b, @core.wram.byteslice(0x100, 2)
  end

  def test_work_ram_written_from_ruby_reaches_the_cartridge_in_the_same_order
    @core.wram_write32(0xFF0200, 0xDEADBEEF)
    assert_equal 0xDEADBEEF, @core.wram_read32(0x0200)
    assert_equal "\xDE\xAD\xBE\xEF".b, @core.wram.byteslice(0x200, 4)
  end

  def test_colour_memory_reads_what_the_cartridge_wrote
    assert_equal COLOR, @core.cram.unpack1("v")
    assert_equal 0b110_100_010, @core.color_ram.first
  end

  def test_video_ram_reads_what_the_cartridge_wrote_high_byte_first
    assert_equal [0xA5, 0xC3], @core.vram.byteslice(0x8000, 2).bytes
  end

  def test_vertical_scroll_memory_reads_what_the_cartridge_wrote
    assert_equal 0x0123, @core.vsram.unpack1("v")
  end

  def test_the_video_registers_say_how_the_chip_was_set_up
    registers = @core.vdp_registers
    assert_equal [0x44, 0x81, 0x02], [registers[1], registers[12], registers[15]]
  end

  def test_the_processors_registers_say_where_it_is
    registers = @core.registers
    assert_includes 0x200..0x300, registers.fetch(:pc)
    assert_equal 0x00FF0000, registers.fetch(:a7)
  end

  def test_two_cores_are_two_consoles
    other = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(Dir.mktmpdir, LOOP))
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
    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, LOOP))
    @core.run_frame

    refute_equal 0x1234, @core.wram_read16(0x0100)
    refute_equal COLOR, @core.cram.unpack1("v")
    refute_equal [0xA5, 0xC3], @core.vram.byteslice(0x8000, 2).bytes
  end

  def test_the_buttons_set_from_ruby_are_the_ones_the_pad_reports_as_down
    @core.destroy
    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, PAD_CODE))
    @core.run_frame
    assert_equal 0x3F, @core.wram_read8(0x0102) & 0x3F, "nothing is down: every bit is 1"

    @core.set_buttons(%i[b right])
    @core.run_frame
    assert_equal 0b100111, @core.wram_read8(0x0102) & 0x3F, "B is bit 4 and right is bit 3, 0 where down"
  end

  def test_a_button_a_genesis_pad_lacks_is_refused
    assert_raises(ArgumentError) { @core.set_buttons(%i[select]) }
  end
end
