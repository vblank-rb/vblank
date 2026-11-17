# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# AN EXE MADE BY OUR OWN ASSEMBLER AND MZ WRITER, run in DOSBox and read back: the picture it drew, and a
# word it stored in a segment DOS chose the place of, which only works if the header's relocations are right.
class TestDOSEXE < Minitest::Test
  X86 = VBlank::IR::Backends::DOS::X86
  DOSEXE = VBlank::Cartridge::DOSEXE

  GREY = 0xAAAAAA # colour 7 of the card's own palette, 2Ah of 3Fh a channel, shown in 8 bits
  MARKER = 0xBEEF
  DATA_SEGMENT_AT = VBlank::Diagnostics::DOSMemory::DATA_SEGMENT_AT

  # Mode 13h, a screen of colour 7 stored four bytes at a time, then the data segment loaded (a word the
  # loader relocates), told to the reader at 0040:00F0, a marker stored in it, and a loop with no end.
  private def program
    asm = X86.new
    asm.mov(:ax, 0x13)
    asm.int(0x10)
    asm.mov(:ax, 0xA000)
    asm.mov(:es, :ax)
    asm.xor(:di, :di)
    asm.mov(:cx, 16_000)
    asm.mov(:eax, 0x07070707)
    asm.stos(32, rep: true)
    asm.mov_segment(:ax, :data)
    asm.mov(:ds, :ax)
    asm.xor(:bx, :bx)
    asm.mov(:es, :bx)
    asm.mov(mem_at(DATA_SEGMENT_AT, seg: :es), :ax)
    asm.mov(asm.mem(nil, 0, size: 16), MARKER)
    asm.label("forever")
    asm.jmp("forever")
    asm
  end

  private def mem_at(address, seg: nil) = X86.mem(nil, address, seg: seg)

  # The program as an EXE: its code, then a data segment that starts on a paragraph, and room beyond for the
  # 64K that segment is and the stack at its top.
  private def executable
    asm = program
    code_size = asm.here
    data_segment = (code_size + 15) / 16
    assembled = asm.assemble(data: data_segment)
    image = assembled.bytes.ljust(data_segment * 16, "\0")
    DOSEXE.new(image, title: "TEST", entry: [0, 0], stack: [data_segment, 0xFFFE],
                      relocations: assembled.segment_words.map { |at| [0, at] }, extra_paragraphs: 0x1000)
  end

  private def played(frames)
    Dir.mktmpdir("dos-exe") do |dir|
      path = File.join(dir, "TEST.EXE")
      executable.write(path)
      probe = VBlank::Diagnostics::DOSProbe.new(path, hold: false)
      probe.step(frames)
      yield probe
    ensure
      probe&.close
    end
  end

  def test_the_header_says_what_dos_reads
    bytes = executable.bytes

    assert_equal "MZ", bytes.byteslice(0, 2)
    last_page = bytes.unpack1("@2v")
    pages = bytes.unpack1("@4v")
    assert_equal bytes.bytesize, last_page.zero? ? pages * 512 : ((pages - 1) * 512) + last_page
    assert_equal 32, bytes.unpack1("@8v"), "the header is 32 paragraphs"
    assert_equal 1, bytes.unpack1("@6v"), "one segment word to relocate"
    assert_equal "TEST", executable.title
  end

  # More segment words than fit before the title: the table after it, the header grown to hold it, and the
  # image after that.
  def test_a_program_with_many_segment_words_has_a_longer_header
    many = Array.new(DOSEXE::ROOM_BEFORE_TITLE + 1) { |at| [0, at * 2] }
    bytes = DOSEXE.new("IMAGE".b, title: "X", entry: [0, 0], stack: [0, 0], relocations: many).bytes
    paragraphs = bytes.unpack1("@8v")

    assert_equal [many.size, 512], bytes.unpack("@6v@24v")
    assert_equal [2, 0], bytes.unpack("@516v2"), "the second segment word, after the title"
    assert_equal "X", DOSEXE.title_field_of(bytes).delete("\0")
    assert_equal "IMAGE", bytes.byteslice(paragraphs * 16, 5)
  end

  def test_a_program_with_more_segment_words_than_a_word_counts_is_refused
    too_many = Array.new(DOSEXE::MOST_RELOCATIONS + 1) { [0, 0] }

    assert_raises(ArgumentError) { DOSEXE.new("".b, title: "X", entry: [0, 0], stack: [0, 0], relocations: too_many) }
  end

  def test_the_exe_runs_in_dosbox_and_fills_the_screen
    played(20) do |probe|
      assert_equal [320, 200], [probe.width, probe.height]
      pixels = probe.frame_buffer.unpack("V*")

      assert_equal [0xAAAAAA], pixels.uniq
    end
  end

  def test_the_loader_relocated_the_data_segment_the_program_loaded
    played(20) do |probe|
      assert_equal MARKER, probe.read16(0)
    end
  end
end
