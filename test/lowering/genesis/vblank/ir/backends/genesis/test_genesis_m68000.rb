# frozen_string_literal: true

require "test_helper"

# The 68000 assembler against the bytes a second assembler (GNU as, `-m68000`) makes of the same
# instruction: each expected word below is what that one wrote, and what the Motorola 68000
# Programmer's Reference Manual gives for the instruction's encoding.
class TestGenesisM68000 < Minitest::Test
  M68000 = VBlank::IR::Backends::Genesis::M68000

  # Each instruction as GNU as writes it, and the assembler's call that must make the same bytes.
  ENCODINGS = [
    ["2001", ->(a) { a.move(:l, a.d(1), a.d(0)) }],
    ["3001", ->(a) { a.move(:w, a.d(1), a.d(0)) }],
    ["1001", ->(a) { a.move(:b, a.d(1), a.d(0)) }],
    ["203c12345678", ->(a) { a.move(:l, a.imm(0x12345678), a.d(0)) }],
    ["363c1234", ->(a) { a.move(:w, a.imm(0x1234), a.d(3)) }],
    ["163c0005", ->(a) { a.move(:b, a.imm(5), a.d(3)) }],
    ["2015", ->(a) { a.move(:l, a.ind(5), a.d(0)) }],
    ["202d0008", ->(a) { a.move(:l, a.disp(5, 8), a.d(0)) }],
    ["2b400008", ->(a) { a.move(:l, a.d(0), a.disp(5, 8)) }],
    ["2218", ->(a) { a.move(:l, a.post(0), a.d(1)) }],
    ["2f01", ->(a) { a.move(:l, a.d(1), a.pre(7)) }],
    ["221f", ->(a) { a.move(:l, a.post(7), a.d(1)) }],
    ["3681", ->(a) { a.move(:w, a.d(1), a.ind(3)) }],
    ["23c000c00000", ->(a) { a.move(:l, a.d(0), a.abs_l(0xC00000)) }],
    ["33fc814400c00004", ->(a) { a.move(:w, a.imm(0x8144), a.abs_l(0xC00004)) }],
    ["203900ff8000", ->(a) { a.move(:l, a.abs_l(0xFF8000), a.d(0)) }],
    ["30387ffe", ->(a) { a.move(:w, a.abs_w(0x7FFE), a.d(0)) }],
    ["2449", ->(a) { a.movea(:l, a.a(1), a.a(2)) }],
    ["207c00001234", ->(a) { a.movea(:l, a.imm(0x1234), a.a(0)) }],
    ["3040", ->(a) { a.movea(:w, a.d(0), a.a(0)) }],
    ["7005", ->(a) { a.moveq(5, a.d(0)) }],
    ["7eff", ->(a) { a.moveq(-1, a.d(7)) }],
    ["d081", ->(a) { a.add(:l, a.d(1), a.d(0)) }],
    ["d280", ->(a) { a.add(:l, a.d(0), a.d(1)) }],
    ["d0ad0004", ->(a) { a.add(:l, a.disp(5, 4), a.d(0)) }],
    ["d1ad0004", ->(a) { a.add(:l, a.d(0), a.disp(5, 4)) }],
    ["5280", ->(a) { a.addq(:l, 1, a.d(0)) }],
    ["50ad0004", ->(a) { a.addq(:l, 8, a.disp(5, 4)) }],
    ["5648", ->(a) { a.addq(:w, 3, a.a(0)) }],
    ["5382", ->(a) { a.subq(:l, 1, a.d(2)) }],
    ["9081", ->(a) { a.sub(:l, a.d(1), a.d(0)) }],
    ["048000000064", ->(a) { a.sub(:l, a.imm(100), a.d(0)) }],
    ["06ad000000640004", ->(a) { a.add(:l, a.imm(100), a.disp(5, 4)) }],
    ["b081", ->(a) { a.cmp(:l, a.d(1), a.d(0)) }],
    ["b0ad0004", ->(a) { a.cmp(:l, a.disp(5, 4), a.d(0)) }],
    ["0c8000000005", ->(a) { a.cmp(:l, a.imm(5), a.d(0)) }],
    ["0cad000000050004", ->(a) { a.cmp(:l, a.imm(5), a.disp(5, 4)) }],
    ["0c400005", ->(a) { a.cmp(:w, a.imm(5), a.d(0)) }],
    ["0c000005", ->(a) { a.cmp(:b, a.imm(5), a.d(0)) }],
    ["b1c9", ->(a) { a.cmp(:l, a.a(1), a.a(0)) }],
    ["c081", ->(a) { a.and(:l, a.d(1), a.d(0)) }],
    ["0280000000ff", ->(a) { a.and(:l, a.imm(0xFF), a.d(0)) }],
    ["8081", ->(a) { a.or(:l, a.d(1), a.d(0)) }],
    ["008000000001", ->(a) { a.or(:l, a.imm(1), a.d(0)) }],
    ["b380", ->(a) { a.eor(:l, a.d(1), a.d(0)) }],
    ["0a800000ffff", ->(a) { a.eor(:l, a.imm(0xFFFF), a.d(0)) }],
    ["4680", ->(a) { a.not(:l, a.d(0)) }],
    ["4480", ->(a) { a.neg(:l, a.d(0)) }],
    ["4280", ->(a) { a.clr(:l, a.d(0)) }],
    ["42ad0004", ->(a) { a.clr(:l, a.disp(5, 4)) }],
    ["426d0004", ->(a) { a.clr(:w, a.disp(5, 4)) }],
    ["4a80", ->(a) { a.tst(:l, a.d(0)) }],
    ["4aad0004", ->(a) { a.tst(:l, a.disp(5, 4)) }],
    ["4880", ->(a) { a.ext(:w, a.d(0)) }],
    ["48c0", ->(a) { a.ext(:l, a.d(0)) }],
    ["4840", ->(a) { a.swap(a.d(0)) }],
    ["e588", ->(a) { a.lsl(:l, 2, a.d(0)) }],
    ["e188", ->(a) { a.lsl(:l, 8, a.d(0)) }],
    ["e288", ->(a) { a.lsr(:l, 1, a.d(0)) }],
    ["e781", ->(a) { a.asl(:l, 3, a.d(1)) }],
    ["e881", ->(a) { a.asr(:l, 4, a.d(1)) }],
    ["e4a1", ->(a) { a.asr(:l, a.d(2), a.d(1)) }],
    ["e5a8", ->(a) { a.lsl(:l, a.d(2), a.d(0)) }],
    ["e248", ->(a) { a.lsr(:w, 1, a.d(0)) }],
    ["e058", ->(a) { a.ror(:w, 8, a.d(0)) }],
    ["e398", ->(a) { a.rol(:l, 1, a.d(0)) }],
    ["08000003", ->(a) { a.btst(3, a.d(0)) }],
    ["0300", ->(a) { a.btst(a.d(1), a.d(0)) }],
    ["082d00030004", ->(a) { a.btst(3, a.disp(5, 4)) }],
    ["08c00003", ->(a) { a.bset(3, a.d(0)) }],
    ["08800003", ->(a) { a.bclr(3, a.d(0)) }],
    ["03c0", ->(a) { a.bset(a.d(1), a.d(0)) }],
    ["c0c1", ->(a) { a.mulu(a.d(1), a.d(0)) }],
    ["c1c1", ->(a) { a.muls(a.d(1), a.d(0)) }],
    ["80c1", ->(a) { a.divu(a.d(1), a.d(0)) }],
    ["81c1", ->(a) { a.divs(a.d(1), a.d(0)) }],
    ["c0fc000a", ->(a) { a.mulu(a.imm(10), a.d(0)) }],
    ["41ed0004", ->(a) { a.lea(a.disp(5, 4), a.a(0)) }],
    ["41f900ff8000", ->(a) { a.lea(a.abs_l(0xFF8000), a.a(0)) }],
    ["45f01800", ->(a) { a.lea(a.idx(0, 0, 1), a.a(2)) }],
    ["45f01002", ->(a) { a.lea(a.idx(0, 2, 1, :w), a.a(2)) }],
    ["486d0004", ->(a) { a.pea(a.disp(5, 4)) }],
    ["4eb912345678", ->(a) { a.jsr(a.abs_l(0x12345678)) }],
    ["4ef912345678", ->(a) { a.jmp(a.abs_l(0x12345678)) }],
    ["4e90", ->(a) { a.jsr(a.ind(0)) }],
    ["4ed0", ->(a) { a.jmp(a.ind(0)) }],
    ["4e75", ->(a) { a.rts }],
    ["4e73", ->(a) { a.rte }],
    ["4e71", ->(a) { a.nop }],
    ["4e722000", ->(a) { a.stop(0x2000) }],
    ["40c0", ->(a) { a.move_from_sr(a.d(0)) }],
    ["46c0", ->(a) { a.move_to_sr(a.d(0)) }],
    ["46fc2700", ->(a) { a.move_to_sr(a.imm(0x2700)) }],
    ["007c0700", ->(a) { a.ori_to_sr(0x0700) }],
    ["027cf8ff", ->(a) { a.andi_to_sr(0xF8FF) }],
    ["4e40", ->(a) { a.trap(0) }],
    ["48e7fffe", ->(a) { a.movem_push(:l, :d0, :d1, :d2, :d3, :d4, :d5, :d6, :d7, :a0, :a1, :a2, :a3, :a4, :a5, :a6) }],
    ["4cdf7fff", ->(a) { a.movem_pop(:l, :d0, :d1, :d2, :d3, :d4, :d5, :d6, :d7, :a0, :a1, :a2, :a3, :a4, :a5, :a6) }],
    ["48e73000", ->(a) { a.movem_push(:l, :d2, :d3) }],
    ["4cdf000c", ->(a) { a.movem_pop(:l, :d2, :d3) }],
    ["1018", ->(a) { a.move(:b, a.post(0), a.d(0)) }],
    ["10c0", ->(a) { a.move(:b, a.d(0), a.post(0)) }],
    ["32d8", ->(a) { a.move(:w, a.post(0), a.post(1)) }],
    ["20301804", ->(a) { a.move(:l, a.idx(0, 4, 1), a.d(0)) }],
    ["21801800", ->(a) { a.move(:l, a.d(0), a.idx(0, 0, 1)) }],
    ["303cffff", ->(a) { a.move(:w, a.imm(-1), a.d(0)) }],
    ["56c0", ->(a) { a.scc(:ne, a.d(0)) }],
    ["57c0", ->(a) { a.scc(:eq, a.d(0)) }],
    ["5dc0", ->(a) { a.scc(:lt, a.d(0)) }],
    ["5cc0", ->(a) { a.scc(:ge, a.d(0)) }],
    ["5ec0", ->(a) { a.scc(:gt, a.d(0)) }],
    ["5fc0", ->(a) { a.scc(:le, a.d(0)) }],
    ["52c0", ->(a) { a.scc(:hi, a.d(0)) }],
    ["53c0", ->(a) { a.scc(:ls, a.d(0)) }],
    ["55c0", ->(a) { a.scc(:cs, a.d(0)) }],
    ["4e70", ->(a) { a.reset }],
    ["4afc", ->(a) { a.illegal }],
    ["200f", ->(a) { a.move(:l, a.a(7), a.d(0)) }],
    ["4440", ->(a) { a.neg(:w, a.d(0)) }],
    ["4600", ->(a) { a.not(:b, a.d(0)) }],
    ["13fc004000a10009", ->(a) { a.move(:b, a.imm(0x40), a.abs_l(0xA10009)) }],
    ["103900a10003", ->(a) { a.move(:b, a.abs_l(0xA10003), a.d(0)) }],
    ["13c000ff0102", ->(a) { a.move(:b, a.d(0), a.abs_l(0xFF0102)) }]
  ].freeze

  # `and.l #0xFF,d0` is ANDI: 0280 and a long number.
  def test_every_instruction_is_the_bytes_the_other_assembler_makes
    wrong = ENCODINGS.filter_map do |expected, call|
      asm = M68000.new("t")
      call.call(asm)
      made = asm.bytes.unpack1("H*")
      "#{made} for #{expected}" unless made == expected.delete(" ")
    end

    assert_empty wrong
  end

  def test_a_branch_to_a_label_is_a_distance_from_its_own_word
    asm = M68000.new("t")
    asm.label("top")
    asm.nop
    asm.branch(:ne, "top")
    section = asm.section

    assert_equal [M68000::Fixup.new(offset: 4, kind: :rel16, label: "top", plus: 0)], section.fixups
    assert_equal "4e71" "6600" "0000", section.bytes.unpack1("H*")
    assert_equal({ "top" => 0 }, section.labels)
  end

  def test_the_address_of_a_label_is_a_long_to_be_filled_in
    asm = M68000.new("t")
    asm.jsr(asm.abs_l("routine"))
    asm.move(:l, asm.imm("table"), asm.d(0))

    assert_equal %i[abs32 abs32], asm.section.fixups.map(&:kind)
    assert_equal [2, 8], asm.section.fixups.map(&:offset)
  end

  def test_a_section_is_a_whole_number_of_words
    asm = M68000.new("t")
    asm.data_bytes(1, 2, 3)

    assert_equal 4, asm.section.size
  end

  def test_a_number_is_kept_high_byte_first
    asm = M68000.new("t")
    asm.data_words(0x1234)
    asm.data_longs(0xDEADBEEF)

    assert_equal "1234deadbeef", asm.bytes.unpack1("H*")
  end

  def test_an_instruction_the_processor_lacks_is_refused
    asm = M68000.new("t")

    assert_raises(M68000::Error) { asm.move(:l, asm.d(0), asm.a(0)) }
    assert_raises(M68000::Error) { asm.moveq(200, asm.d(0)) }
    assert_raises(M68000::Error) { asm.addq(:l, 9, asm.d(0)) }
    assert_raises(M68000::Error) { asm.lsl(:l, 9, asm.d(0)) }
    assert_raises(M68000::Error) { asm.d(8) }
  end

  def test_a_label_is_placed_once
    asm = M68000.new("t")
    asm.label("here")

    assert_raises(M68000::Error) { asm.label("here") }
  end
end
