# frozen_string_literal: true

require_relative "test_helper"
require "weakref"

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

  # A state saved puts back the work RAM it was saved with, over whatever was written after.
  def test_a_saved_state_puts_work_ram_back
    @core.wram_write32(0xFF8000, 0x1234_5678)
    state = @core.serialize
    @core.wram_write32(0xFF8000, 0x0BAD_F00D)
    @core.unserialize(state)

    assert_equal 0x1234_5678, @core.wram_read32(0xFF8000)
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

  # Reads a Team Player in the second port the way plutiedev's "Sega multitap" gives: TH and TR made
  # outputs, then TR toggled for each nibble after the first two, every nibble's low four bits
  # stored at $FF0110 on. Nibbles 0 and 1 are the start (%0011, %1111), 2 and 3 noughts, 4 to 7 the
  # four plugs' kinds, then each plug's two nibbles of buttons (right, left, down, up; then start,
  # A, C, B), 0 where a button is down.
  PAD2_DATA = 0xA10005
  PAD2_CONTROL = 0xA1000B
  TEAM_PLAYER_WRITES = [0x60, 0x20, 0x00, 0x20, 0x00, 0x20, 0x00, 0x20, 0x00, 0x20, 0x00, 0x20].freeze
  TEAM_PLAYER_CODE = [
    *move_byte(0x60, PAD2_CONTROL),
    *TEAM_PLAYER_WRITES.each_with_index.flat_map { |value, nibble| [*move_byte(value, PAD2_DATA), *copy_byte(PAD2_DATA, 0xFF0110 + nibble)] },
    *LOOP
  ].freeze

  # Port 1 of #set_buttons is the tap's first plug, port 2 its second.
  def test_a_team_player_in_the_second_port_hands_over_its_plugs
    @core.destroy
    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, TEAM_PLAYER_CODE))
    @core.plug_in_team_player
    @core.set_buttons(%i[right], port: 1)
    @core.set_buttons(%i[b], port: 2)
    @core.run_frame
    nibbles = (0...TEAM_PLAYER_WRITES.size).map { |nibble| @core.wram_read8(0xFF0110 + nibble) & 0x0F }

    assert_equal [0b0011, 0b1111, 0, 0], nibbles.first(4), "the tap's start"
    assert_equal [0, 0, 0, 0], nibbles[4, 4], "four three-button pads"
    assert_equal [0b0111, 0b1111], nibbles[8, 2], "the first plug's right"
    assert_equal [0b1111, 0b1110], nibbles[10, 2], "the second plug's B"
  end

  def test_a_button_a_genesis_pad_lacks_is_refused
    assert_raises(ArgumentError) { @core.set_buttons(%i[select]) }
  end

  # Save memory is a byte at each odd address from $200000. The core hands over as much of it as was
  # written to, up to the last byte that is not $FF, which is what a chip nobody wrote to holds.
  SAVE_CODE = [*move_byte(0x5A, 0x200001), *move_byte(0x5A, 0x200003), *LOOP].freeze

  def test_save_memory_holds_what_the_cartridge_saved
    @core.destroy
    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, SAVE_CODE))
    @core.run_frame
    assert_equal "\xFF\x5A\xFF\x5A".b, @core.save_ram
  end

  # A console nobody destroyed is collected by Ruby in the end, and its copy of the core is handed to
  # the next console made in this process. The next console must start with save memory of its own,
  # never the dropped console's.
  def test_a_console_left_without_destroy_hands_its_save_to_nobody
    @core.destroy
    @core = nil
    dropped = Thread.new { drop_console(SAVE_CODE) }.value
    collect_dropped_consoles
    refute dropped.weakref_alive?, "the dropped console was collected, so its copy is free for the next"

    @core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(@dir, LOOP))
    @core.run_frame
    assert_empty @core.save_ram, "the new console started from the dropped console's save"
  end

  # The copy of the core a dropped console gives back holds no cartridge: Ruby shuts the console as
  # #destroy does. A copy left with the cartridge in it is a library never shut, which the next
  # console's start goes on top of.
  def test_a_console_left_without_destroy_leaves_no_cartridge_in_its_copy
    @core.destroy
    @core = nil
    dropped = Thread.new { drop_console(CODE) }.value
    collect_dropped_consoles
    refute dropped.weakref_alive?, "the dropped console was collected, so its copy is free for the next"

    refute_equal [0x12, 0x34], work_ram_in_next_copy(0x0100, 2), "the copy still holds the dropped console's work RAM"
  end

  # Made and played on a thread of its own and let go of there: Ruby looks for what is still held on
  # every stack, and a word left on the test's own could keep the console from being collected. Hands
  # back a weak reference, which says whether the console is still alive without keeping it so.
  private def drop_console(code)
    core = RubyGenesisEmulator::Core.new(HandMadeCartridge.write(Dir.mktmpdir, code))
    3.times { core.run_frame }
    WeakRef.new(core)
  end

  private def collect_dropped_consoles = 3.times { GC.start(full_mark: true, immediate_sweep: true) }

  # +count+ bytes of work RAM from +address+, high byte first, in the copy of the core the next console
  # would take, opened as that console opens it, before any cartridge goes in.
  private def work_ram_in_next_copy(address, count)
    copy = RubyGenesisEmulator::KeptCopy.take
    dir = Dir.mktmpdir
    frontend = RubyGenesisEmulator::Frontend.new(copy.path, dir, dir, RubyGenesisEmulator::Core::SETTINGS,
                                                 RubyGenesisEmulator::Core::RGB565)
    ram = RubyGenesisEmulator::Core::SYSTEM_RAM
    Array.new(count) { |i| frontend.memory_read(ram, (address + i) ^ 1, 1).getbyte(0) }
  ensure
    frontend&.close
    copy&.give_back
    FileUtils.rm_rf(dir) if dir
  end
end
