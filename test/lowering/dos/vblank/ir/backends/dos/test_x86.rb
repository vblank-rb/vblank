# frozen_string_literal: true

require "test_helper"

# THE ASSEMBLER'S BYTES, against an assembler that is not ours. Each expected line was made by GNU as
# (`as --32` with `.code16` and `.intel_syntax noprefix`) and read back with objdump, so no answer here is
# worked out the way the code works it out. The first column is the instruction as written to the
# assembler, the second the bytes it made, each in hex.
class TestX86 < Minitest::Test
  X86 = VBlank::IR::Backends::DOS::X86

  # [what is called on the assembler, GNU as's bytes]
  ENCODINGS = [
    [-> { mov(:ax, 0x13) }, "b8 13 00"],
    [-> { mov(:eax, 0x12345678) }, "66 b8 78 56 34 12"],
    [-> { mov(:al, 5) }, "b0 05"],
    [-> { mov(:ds, :ax) }, "8e d8"],
    [-> { mov(:es, :ax) }, "8e c0"],
    [-> { mov(:ax, :ds) }, "8c d8"],
    [-> { xor(:di, :di) }, "31 ff"],
    [-> { stos(16, rep: true) }, "f3 ab"],
    [-> { stos(32, rep: true) }, "66 f3 ab"],
    [-> { movs(8, rep: true) }, "f3 a4"],
    [-> { add(:eax, :ebx) }, "66 01 d8"],
    [-> { add(:eax, 5) }, "66 83 c0 05"],
    [-> { add(:ax, 0x1234) }, "05 34 12"],
    [-> { add(:bx, 0x1234) }, "81 c3 34 12"],
    [-> { cmp(:eax, :ebx) }, "66 39 d8"],
    [-> { sub(:eax, 0x12345) }, "66 2d 45 23 01 00"],
    [-> { self.and(:eax, :ecx) }, "66 21 c8"],
    [-> { self.or(:ecx, :edx) }, "66 09 d1"],
    [-> { imul_wide(:ecx) }, "66 f7 e9"],
    [-> { shrd(:eax, :edx, 16) }, "66 0f ac d0 10"],
    [-> { shld(:edx, :eax, :cl) }, "66 0f a5 c2"],
    [-> { add(:al, 3) }, "04 03"],
    [-> { mov(:eax, mem(nil, 0x100)) }, "66 a1 00 01"],
    [-> { mov(mem(nil, 0x100), :eax) }, "66 a3 00 01"],
    [-> { mov(:eax, mem(:bx, 4)) }, "66 8b 47 04"],
    [-> { mov(:ax, mem(:bx, 0, index: :si)) }, "8b 00"],
    [-> { mov(mem(:bp, 0), :ax) }, "89 46 00"],
    [-> { mov(:eax, mem(:bx, 300, index: :si)) }, "66 8b 80 2c 01"],
    [-> { mov(:bl, mem(:si, 0)) }, "8a 1c"],
    [-> { mov(:ax, mem(:bx, 0, seg: :es)) }, "26 8b 07"],
    [-> { imul(:eax, :ebx) }, "66 0f af c3"],
    [-> { cdq }, "66 99"],
    [-> { idiv(:ebx) }, "66 f7 fb"],
    [-> { mul(:ebx) }, "66 f7 e3"],
    [-> { neg(:eax) }, "66 f7 d8"],
    [-> { self.not(:eax) }, "66 f7 d0"],
    [-> { shl(:eax, :cl) }, "66 d3 e0"],
    [-> { sar(:eax, 3) }, "66 c1 f8 03"],
    [-> { sete(:al) }, "0f 94 c0"],
    [-> { movzx(:eax, :al) }, "66 0f b6 c0"],
    [-> { movsx(:eax, :bx) }, "66 0f bf c3"],
    [-> { lea(:bx, mem(:bx, 4)) }, "8d 5f 04"],
    [-> { push(:ax) }, "50"],
    [-> { push(:eax) }, "66 50"],
    [-> { pop(:ds) }, "1f"],
    [-> { push(:fs) }, "0f a0"],
    [-> { pop(:fs) }, "0f a1"],
    [-> { push(:gs) }, "0f a8"],
    [-> { pop(:gs) }, "0f a9"],
    [-> { mov(:fs, :ax) }, "8e e0"],
    [-> { mov(:di, :fs) }, "8c e7"],
    [-> { in_from_dx(:al) }, "ec"],
    [-> { out_to_dx(:al) }, "ee"],
    [-> { out_to_dx(:ax) }, "ef"],
    [-> { int(0x10) }, "cd 10"],
    [-> { ret }, "c3"],
    [-> { test(:eax, :eax) }, "66 85 c0"],
    [-> { inc(:ax) }, "40"],
    [-> { dec(:ecx) }, "66 49"],
    [-> { xchg(:ax, :bx) }, "93"]
  ].freeze

  # A place in memory with a number and no register, where the place says its size. These were made by
  # LLVM's assembler (`clang -c -target i386-none-elf`, `.code16` and `.intel_syntax noprefix`, the size
  # written as `byte ptr`, `word ptr` or `dword ptr`) and read back as the section's raw bytes.
  SIZED_MEMORY_ENCODINGS = [
    [-> { mov(mem(:bx, 5, size: 8), 1) }, "c6 47 05 01"],
    [-> { mov(mem(nil, 0, size: 16), 0x1234) }, "c7 06 00 00 34 12"],
    [-> { mov(mem(nil, 0x100, size: 32), 0x12345678) }, "66 c7 06 00 01 78 56 34 12"],
    [-> { cmp(mem(nil, 0x80, seg: :es, size: 8), 2) }, "26 80 3e 80 00 02"],
    [-> { add(mem(nil, 0x100, size: 32), 5) }, "66 83 06 00 01 05"],
    [-> { add(mem(nil, 0x100, size: 32), 0x12345) }, "66 81 06 00 01 45 23 01 00"],
    [-> { inc(mem(:bx, 0, size: 16)) }, "ff 07"],
    [-> { test(mem(nil, 0x100, size: 32), 0x10000) }, "66 f7 06 00 01 00 00 01 00"]
  ].freeze

  def test_each_instruction_is_the_bytes_an_independent_assembler_makes
    (ENCODINGS + SIZED_MEMORY_ENCODINGS).each do |written, expected|
      asm = X86.new
      asm.instance_exec(&written)

      assert_equal expected, asm.assemble.bytes.unpack("C*").map { |byte| format("%02x", byte) }.join(" "), expected
    end
  end

  # A jump's distance is from the end of the jump: E9 then a signed 16-bit word (Intel's manual, JMP).
  def test_a_jump_forward_and_back_has_its_distance_from_the_instruction_after_it
    asm = X86.new
    asm.label("top")
    asm.nop
    asm.jmp("end")
    asm.nop
    asm.nop
    asm.label("end")
    asm.je("top")

    assert_equal "90 e9 02 00 90 90 0f 84 f6 ff", hex(asm.assemble.bytes)
  end

  def test_a_call_is_a_jump_with_its_own_opcode
    asm = X86.new
    asm.call("there")
    asm.label("there")

    assert_equal "e8 00 00", hex(asm.assemble.bytes)
  end

  def test_a_segment_word_is_filled_from_the_names_and_listed_for_the_loader
    asm = X86.new
    asm.nop
    asm.mov_segment(:ax, :data)

    assembled = asm.assemble(data: 0x0123)

    assert_equal "90 b8 23 01", hex(assembled.bytes)
    assert_equal [2], assembled.segment_words
  end

  # A routine handed over by its address (an interrupt's): B8 + the register, then where the label is.
  def test_a_label_s_offset_is_loaded_as_a_number
    asm = X86.new
    asm.nop
    asm.mov_offset(:ax, "routine")
    asm.nop
    asm.label("routine")

    assert_equal "90 b8 05 00 90", hex(asm.assemble.bytes)
  end

  def test_a_label_that_is_never_placed_is_refused
    asm = X86.new
    asm.jmp("nowhere")

    assert_raises(X86::Error) { asm.assemble }
  end

  def test_a_label_named_twice_is_refused
    asm = X86.new
    asm.label("again")

    assert_raises(X86::Error) { asm.label("again") }
  end

  def test_a_number_too_big_for_the_register_is_refused
    assert_raises(X86::Error) { X86.new.mov(:al, 300) }
  end

  def test_a_number_too_big_for_the_arithmetic_is_refused
    assert_raises(X86::Error) { X86.new.add(:al, 300) }
    assert_raises(X86::Error) { X86.new.add(:ax, 0x1_0000) }
    assert_raises(X86::Error) { X86.new.cmp(X86.mem(nil, 0, size: 8), -129) }
  end

  # Without a size the instruction could be a byte's, a word's or a doubleword's.
  def test_memory_with_a_number_and_no_size_is_refused
    asm = X86.new

    assert_raises(X86::Error) { asm.mov(X86.mem(nil, 0x100), 1) }
    assert_raises(X86::Error) { asm.add(X86.mem(:bx, 4), 1) }
    assert_raises(X86::Error) { asm.inc(X86.mem(:bx, 0)) }
  end

  # 16-bit addressing has eight shapes (bx or bp, plus si or di, or one of the four alone); no other is an
  # address, and [si] cannot be an index alone.
  def test_an_address_16_bit_code_cannot_name_is_refused
    assert_raises(X86::Error) { X86.mem(nil, 4, index: :si) }
    assert_raises(X86::Error) { X86.mem(:si, 0, index: :bx) }
    assert_raises(X86::Error) { X86.mem(:ax) }
  end

  # A register of one size and a place that says another would move part of a number, or spill past it.
  def test_a_register_and_a_place_of_different_sizes_are_refused
    asm = X86.new

    assert_raises(X86::Error) { asm.mov(X86.mem(nil, 0x100, size: 32), :ax) }
    assert_raises(X86::Error) { asm.mov(:al, X86.mem(:bx, 0, size: 32)) }
    assert_raises(X86::Error) { asm.add(:eax, X86.mem(:bx, 0, size: 16)) }
    assert_equal "66 a1 00 01", hex(asm.mov(:eax, X86.mem(nil, 0x100, size: 32)).assemble.bytes)
  end

  private def hex(bytes) = bytes.unpack("C*").map { |byte| format("%02x", byte) }.join(" ")
end
