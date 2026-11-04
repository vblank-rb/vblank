# frozen_string_literal: true

require "test_helper"

# The PS-X EXE's header, checked against the layout psx-spx gives ("CDROM File Formats", PS-X EXE) and
# the checks Beetle PSX makes of one before it loads it (libretro.c, LoadEXE): "PS-X EXE" at 0, the entry
# point at 10h, the load address at 18h, the code's size at 1Ch, the stack at 30h, the code from 800h and
# exactly as long as the size says, a multiple of 2048.
class TestPS1EXE < Minitest::Test
  PS1EXE = VBlank::Cartridge::PS1EXE

  private def exe(code = "\0".b * 100, **options) = PS1EXE.new(code, title: "Pong", entry: 0x8001_0040, **options)
  private def word_at(bytes, at) = bytes.byteslice(at, 4).unpack1("V")

  def test_the_header_names_the_format_where_to_start_and_where_the_code_goes
    bytes = exe.bytes

    assert_equal "PS-X EXE", bytes.byteslice(0, 8)
    assert_equal 0x8001_0040, word_at(bytes, 0x10), "the entry point"
    assert_equal 0x8001_0000, word_at(bytes, 0x18), "the load address"
  end

  def test_the_code_is_a_whole_number_of_blocks_and_exactly_as_long_as_the_header_says
    bytes = exe("\x01".b * 3000).bytes
    size = word_at(bytes, 0x1C)

    assert_equal 4096, size
    assert_equal 0x800 + size, bytes.bytesize
    assert_equal "\x01".b * 3000, bytes.byteslice(0x800, 3000)
  end

  def test_the_stack_starts_at_the_top_of_ram
    assert_equal 0x801F_FFF0, word_at(exe.bytes, 0x30)
  end

  def test_the_title_is_in_the_text_and_no_licence_text_is
    built = exe

    assert_equal "Pong", built.title
    refute_match(/Sony|Licensed/, built.bytes.byteslice(0, 0x800))
  end

  def test_an_exe_is_told_from_other_files_by_its_first_eight_bytes
    assert PS1EXE.header?(exe.bytes)
    refute PS1EXE.header?("SEGA MEGA DRIVE ".b * 200)
    assert_equal :ps1, exe.console
  end

  def test_a_program_past_where_a_program_may_reach_is_refused
    assert_raises(ArgumentError) { exe("\0".b * (VBlank::Console::PS1Hardware::PROGRAM_END - 0x8001_0000 + 1)) }
  end
end
