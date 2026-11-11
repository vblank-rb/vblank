# frozen_string_literal: true

require "test_helper"

# The R3000A assembler against the words a second assembler makes of the same instruction: each
# expected word below is what LLVM's (`llvm-mc -triple=mipsel -mcpu=mips1 -show-encoding`) wrote,
# except RFE, which LLVM does not know for MIPS I and psx-spx gives as 42000010h ("COP0 cmd 10h").
class TestPS1R3000 < Minitest::Test
  R3000 = VBlank::IR::Backends::PS1::R3000

  ENCODINGS = [
    [0x00000000, ->(a) { a.nop }],
    [0x03E00008, ->(a) { a.jr(:ra, delay: :none) }],
    [0x27BDFFF0, ->(a) { a.addiu(:sp, :sp, -16) }],
    [0x3C011F80, ->(a) { a.lui(:at, 0x1F80) }],
    [0x8FA80004, ->(a) { a.lw(:t0, 4, :sp) }],
    [0xAFBF0000, ->(a) { a.sw(:ra, 0, :sp) }],
    [0x00851021, ->(a) { a.addu(:v0, :a0, :a1) }],
    [0x00851023, ->(a) { a.subu(:v0, :a0, :a1) }],
    [0x00850018, ->(a) { a.mult(:a0, :a1) }],
    [0x0085001A, ->(a) { a.div(:a0, :a1) }],
    [0x0085001B, ->(a) { a.divu(:a0, :a1) }],
    [0x00850019, ->(a) { a.multu(:a0, :a1) }],
    [0x00001012, ->(a) { a.mflo(:v0) }],
    [0x00001810, ->(a) { a.mfhi(:v1) }],
    [0x01000013, ->(a) { a.mtlo(:t0) }],
    [0x01200011, ->(a) { a.mthi(:t1) }],
    [0x00094080, ->(a) { a.sll(:t0, :t1, 2) }],
    [0x000947C2, ->(a) { a.srl(:t0, :t1, 31) }],
    [0x00094403, ->(a) { a.sra(:t0, :t1, 16) }],
    [0x01494004, ->(a) { a.sllv(:t0, :t1, :t2) }],
    [0x01494006, ->(a) { a.srlv(:t0, :t1, :t2) }],
    [0x01494007, ->(a) { a.srav(:t0, :t1, :t2) }],
    [0x02328024, ->(a) { a.and(:s0, :s1, :s2) }],
    [0x02328025, ->(a) { a.or(:s0, :s1, :s2) }],
    [0x02328026, ->(a) { a.xor(:s0, :s1, :s2) }],
    [0x02328027, ->(a) { a.nor(:s0, :s1, :s2) }],
    [0x0085102A, ->(a) { a.slt(:v0, :a0, :a1) }],
    [0x0085102B, ->(a) { a.sltu(:v0, :a0, :a1) }],
    [0x3108FFFF, ->(a) { a.andi(:t0, :t0, 0xFFFF) }],
    [0x35081234, ->(a) { a.ori(:t0, :t0, 0x1234) }],
    [0x39280001, ->(a) { a.xori(:t0, :t1, 1) }],
    [0x2928FFFF, ->(a) { a.slti(:t0, :t1, -1) }],
    [0x2D280005, ->(a) { a.sltiu(:t0, :t1, 5) }],
    [0x8088FFFF, ->(a) { a.lb(:t0, -1, :a0) }],
    [0x90880002, ->(a) { a.lbu(:t0, 2, :a0) }],
    [0x8488FFFE, ->(a) { a.lh(:t0, -2, :a0) }],
    [0x94880006, ->(a) { a.lhu(:t0, 6, :a0) }],
    [0xA3880003, ->(a) { a.sb(:t0, 3, :gp) }],
    [0xA7880008, ->(a) { a.sh(:t0, 8, :gp) }],
    [0x0320F809, ->(a) { a.jalr(:t9, delay: :none) }],
    [0x401A6800, ->(a) { a.mfc0(:k0, 13) }],
    [0x40806000, ->(a) { a.mtc0(:zero, 12) }],
    [0x42000010, ->(a) { a.rfe }],
    [0x0000000C, ->(a) { a.syscall }],
    [0x0000000D, ->(a) { a.break_code }]
  ].freeze

  private def words(asm) = asm.section.bytes.unpack("V*")

  private def word_of(build)
    asm = R3000.new("one")
    build.call(asm)
    words(asm)
  end

  def test_each_instruction_is_the_word_llvm_writes
    ENCODINGS.each do |expected, build|
      assert_equal [expected], word_of(build), format("expected %08X", expected)
    end
  end

  # The same branches LLVM wrote for a program with a label behind and one ahead: each word counts in
  # instructions from the one after the branch, and each branch is followed by a nop in its slot.
  def test_branches_count_from_the_instruction_after_them
    asm = R3000.new("branches")
    asm.label("back")
    asm.nop
    asm.beq(:t0, :t1, "ahead")
    asm.bne(:t0, :zero, "back")
    asm.blez(:a0, "ahead")
    asm.bgtz(:a0, "back")
    asm.bltz(:a0, "ahead")
    asm.bgez(:a0, "ahead")
    asm.label("ahead")
    asm.nop
    linked = VBlank::IR::Backends::PS1::Linker.new([asm.section]).link

    assert_equal [0, 0x1109000B, 0, 0x1500FFFC, 0, 0x18800007, 0, 0x1C80FFF8, 0, 0x04800003, 0, 0x04810001, 0, 0],
                 linked.image.unpack("V*")
  end

  def test_a_jump_names_the_place_in_the_same_256_megabytes
    asm = R3000.new("jumps")
    asm.jal("there")
    asm.label("there")
    asm.j("there")
    linked = VBlank::IR::Backends::PS1::Linker.new([asm.section]).link
    there = linked.address_of("there")

    assert_equal [0x0C000000 | ((there >> 2) & 0x3FFFFFF), 0, 0x08000000 | ((there >> 2) & 0x3FFFFFF), 0],
                 linked.image.unpack("V*")
  end

  def test_a_label_address_is_lui_and_ori
    asm = R3000.new("address")
    asm.la(:t0, "there")
    asm.label("there")
    linked = VBlank::IR::Backends::PS1::Linker.new([asm.section]).link
    there = linked.address_of("there")

    assert_equal [0x3C080000 | (there >> 16), 0x35080000 | (there & 0xFFFF)], linked.image.unpack("V*")
  end

  # "The loaded data is NOT available to the next opcode" (psx-spx, CPU): a nop goes between a load
  # and an instruction that reads what it loaded, and nowhere else.
  def test_a_load_is_followed_by_a_nop_only_when_the_next_instruction_reads_it
    asm = R3000.new("loads")
    asm.lw(:t0, 0, :sp)
    asm.addu(:v0, :t0, :t1)
    asm.lw(:t0, 0, :sp)
    asm.addu(:v0, :t2, :t1)

    assert_equal [0x8FA80000, 0, 0x01091021, 0x8FA80000, 0x01491021], words(asm)
  end

  def test_a_load_before_a_label_is_followed_by_a_nop
    asm = R3000.new("loads")
    asm.lw(:t0, 0, :sp)
    asm.label("here")
    asm.addu(:v0, :t2, :t1)

    assert_equal [0x8FA80000, 0, 0x01491021], words(asm)
  end

  # MIPS I: an instruction that starts a multiply or a divide within two of reading hi or lo can
  # change what that read gets, so two instructions stand between.
  def test_a_multiply_waits_two_instructions_after_reading_lo
    asm = R3000.new("hilo")
    asm.mflo(:v0)
    asm.mult(:a0, :a1)

    assert_equal [0x00001012, 0, 0, 0x00850018], words(asm)
  end

  def test_a_branch_takes_the_instruction_it_is_handed_for_its_slot
    asm = R3000.new("slot")
    asm.label("top")
    asm.bne(:t0, :zero, "top") { asm.addiu(:t0, :t0, -1) }
    linked = VBlank::IR::Backends::PS1::Linker.new([asm.section]).link

    assert_equal [0x1500FFFF, 0x2508FFFF], linked.image.unpack("V*")
  end

  # A BRANCH'S SLOT IS FILLED WITH THE INSTRUCTION BEFORE IT where running that instruction after the
  # branch has decided comes to the same thing: the processor runs the slot either way.
  ADDIU_T1 = 0x25290001 # addiu t1, t1, 1
  BNE_T0 = 0x15000000   # bne t0, zero

  def test_a_branch_takes_the_instruction_before_it_for_its_slot
    asm = R3000.new("slot")
    asm.label("top")
    asm.addiu(:t1, :t1, 1)
    asm.bne(:t0, :zero, "top")
    linked = VBlank::IR::Backends::PS1::Linker.new([asm.section]).link

    assert_equal [BNE_T0 | 0xFFFF, ADDIU_T1], linked.image.unpack("V*"), "the label names the branch now"
  end

  def test_a_branch_leaves_the_instruction_that_makes_what_it_tests
    asm = R3000.new("slot")
    asm.label("top")
    asm.addiu(:t0, :t0, -1)
    asm.bne(:t0, :zero, "top")

    assert_equal [0x2508FFFF, BNE_T0, 0], words(asm)
  end

  # Code that jumps to a label between the two runs the branch and not the instruction before it.
  def test_a_branch_leaves_an_instruction_a_label_parts_it_from
    asm = R3000.new("slot")
    asm.addiu(:t1, :t1, 1)
    asm.label("top")
    asm.bne(:t0, :zero, "top")

    assert_equal [ADDIU_T1, BNE_T0, 0], words(asm)
  end

  # A load cannot go in a slot, and a branch straight after a load cannot read what it loaded: so the
  # instruction between a load and a branch that reads the load stays where it is.
  def test_a_branch_leaves_a_load_and_the_instruction_keeping_it_from_one
    load = R3000.new("slot")
    load.lw(:t1, 0, :sp)
    load.bne(:t0, :zero, "top")
    kept = R3000.new("slot")
    kept.lw(:t0, 0, :sp)
    kept.addiu(:t1, :t1, 1)
    kept.bne(:t0, :zero, "top")

    assert_equal [0x8FA90000, 0, BNE_T0, 0], words(load)
    assert_equal [0x8FA80000, ADDIU_T1, BNE_T0, 0], words(kept)
  end

  # A call writes the way back into ra as it jumps, before its slot runs: an instruction that reads or
  # writes ra means something else there.
  def test_a_call_takes_an_argument_for_its_slot_and_leaves_ra_alone
    argument = R3000.new("slot")
    argument.addu(:a0, :t0, :zero)
    argument.jal("there")
    saving = R3000.new("slot")
    saving.sw(:ra, 0, :sp)
    saving.jal("there")

    assert_equal [0x0C000000, 0x01002021], words(argument)
    assert_equal [0xAFBF0000, 0x0C000000, 0], words(saving)
  end

  def test_a_return_takes_the_instruction_before_it_unless_it_makes_the_address
    leaving = R3000.new("slot")
    leaving.addiu(:sp, :sp, 16)
    leaving.jr(:ra)
    making = R3000.new("slot")
    making.addu(:t9, :t0, :zero)
    making.jr(:t9)

    assert_equal [0x03E00008, 0x27BD0010], words(leaving)
    assert_equal [0x0100C821, 0x03200008, 0], words(making)
  end

  # An address is two instructions the Linker fills in where they stand, and reading lo is counted
  # from where it stands: neither moves.
  def test_a_branch_leaves_an_instruction_the_linker_fills_in_and_a_read_of_lo
    address = R3000.new("slot")
    address.la(:t1, "there")
    address.b("there")
    lo = R3000.new("slot")
    lo.mflo(:t1)
    lo.b("there")
    lo.mult(:a0, :a1)

    assert_equal [0x3C090000, 0x35290000, 0x10000000, 0], words(address)
    assert_equal [0x00004812, 0x10000000, 0, 0x00850018], words(lo)
  end

  # ...and an instruction moved into a slot is still one instruction since lo was read.
  def test_an_instruction_moved_into_a_slot_is_counted_once_after_reading_lo
    asm = R3000.new("slot")
    asm.mflo(:v0)
    asm.addiu(:t1, :t1, 1)
    asm.b("there")
    asm.mult(:a0, :a1)

    assert_equal [0x00001012, 0x10000000, ADDIU_T1, 0x00850018], words(asm)
  end

  # The slot a branch was handed is its own, and the instruction in it is not the next branch's.
  def test_a_branch_leaves_the_instruction_in_the_slot_before_it
    asm = R3000.new("slot")
    asm.b("there") { asm.addiu(:t1, :t1, 1) }
    asm.b("there")

    assert_equal [0x10000000, ADDIU_T1, 0x10000000, 0], words(asm)
  end

  # ...and so is the instruction after a jump written with no slot of its own.
  def test_a_branch_leaves_the_instruction_after_a_jump_written_without_its_slot
    asm = R3000.new("slot")
    asm.jr(:ra, delay: :none)
    asm.addiu(:t1, :t1, 1)
    asm.b("there")

    assert_equal [0x03E00008, ADDIU_T1, 0x10000000, 0], words(asm)
  end

  def test_an_immediate_out_of_range_is_refused
    assert_raises(R3000::Error) { R3000.new("x").addiu(:t0, :t0, 0x8000) }
    assert_raises(R3000::Error) { R3000.new("x").ori(:t0, :t0, -1) }
    assert_raises(R3000::Error) { R3000.new("x").sll(:t0, :t0, 32) }
  end

  def test_li_takes_one_instruction_when_the_number_fits_sixteen_bits
    assert_equal [0x24080005], word_of(->(a) { a.li(:t0, 5) })
    assert_equal [0x2408FFFF], word_of(->(a) { a.li(:t0, -1) })
    assert_equal [0x3408FFFF], word_of(->(a) { a.li(:t0, 0xFFFF) })
    assert_equal [0x3C081F80], word_of(->(a) { a.li(:t0, 0x1F800000) })
    assert_equal [0x3C081F80, 0x35081070], word_of(->(a) { a.li(:t0, 0x1F801070) })
    assert_equal [0x3C088000, 0x35080001], word_of(->(a) { a.li(:t0, -0x7FFFFFFF) })
  end
end
