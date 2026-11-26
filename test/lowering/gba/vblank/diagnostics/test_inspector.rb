# frozen_string_literal: true

require "test_helper"

require "stringio"

class TestInspector < Minitest::Test
  # Helper: disassemble a single instruction word via Inspector internals.
  private def disasm(word)
    inspector = VBlank::Diagnostics::Inspector.from_rom(minimal_rom)
    desc, = inspector.disassemble(word, Array.new(16, 0))
    desc
  end

  private def minimal_rom
    VBlank.build("TEST", console: :gba, code: "BTST", maker: "01", validate: false, out: nil, err: nil) do
      halt
    end
  end

  # ========================================================================
  # Special instructions
  # ========================================================================

  def test_halt
    assert_includes disasm(0xEAFFFFFE), "HALT"
  end

  def test_nop
    assert_includes disasm(0xE1A00000), "NOP"
  end

  # ========================================================================
  # PUSH / POP
  # ========================================================================

  def test_push_lr
    result = disasm(0xE92D4000)
    assert_includes result, "PUSH"
    assert_includes result, "lr"
  end

  def test_pop_pc
    result = disasm(0xE8BD8000)
    assert_includes result, "POP"
    assert_includes result, "pc"
  end

  def test_push_multiple
    # PUSH {r0, r1, lr}
    result = disasm(0xE92D4003)
    assert_includes result, "PUSH"
    assert_includes result, "r0"
    assert_includes result, "r1"
    assert_includes result, "lr"
  end

  # ========================================================================
  # Branches
  # ========================================================================

  def test_branch_unconditional
    word = VBlank::IR::Backends::GBA::ASM.branch(-10).unpack1("V")
    result = disasm(word)
    assert_includes result, "B"
    refute_includes result, "???"
  end

  def test_branch_conditional_ge
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:ge, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "BGE"
  end

  def test_branch_conditional_lt
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:lt, -2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BLT"
  end

  def test_branch_conditional_eq
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:eq, 3).unpack1("V")
    result = disasm(word)
    assert_includes result, "BEQ"
  end

  def test_branch_conditional_ne
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:ne, 5).unpack1("V")
    result = disasm(word)
    assert_includes result, "BNE"
  end

  def test_branch_conditional_gt
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:gt, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BGT"
  end

  def test_branch_conditional_le
    word = VBlank::IR::Backends::GBA::ASM.branch_cond(:le, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BLE"
  end

  def test_branch_link
    word = VBlank::IR::Backends::GBA::ASM.branch_link(10).unpack1("V")
    result = disasm(word)
    assert_includes result, "BL"
  end

  def test_bx_lr
    result = disasm(0xE12FFF1E)
    assert_includes result, "BX"
    assert_includes result, "lr"
  end

  # ========================================================================
  # Data processing — immediate
  # ========================================================================

  def test_mov_imm
    word = VBlank::IR::Backends::GBA::ASM.load_immediate(3, 42).unpack1("V")
    result = disasm(word)
    assert_includes result, "MOV"
    assert_includes result, "r3"
  end

  def test_add_imm
    word = VBlank::IR::Backends::GBA::ASM.add_imm(10, 10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "ADD"
    assert_includes result, "r10"
    assert_includes result, "0xc"
  end

  def test_sub_imm
    word = VBlank::IR::Backends::GBA::ASM.sub_imm(10, 10, 1).unpack1("V")
    result = disasm(word)
    assert_includes result, "SUB"
    assert_includes result, "r10"
  end

  def test_cmp_imm
    word = VBlank::IR::Backends::GBA::ASM.cmp_imm(10, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "CMP"
    assert_includes result, "r10"
  end

  def test_tst_imm
    word = VBlank::IR::Backends::GBA::ASM.tst_imm(8, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "TST"
    assert_includes result, "r8"
  end

  def test_rsb_imm
    word = VBlank::IR::Backends::GBA::ASM.rsb_imm(10, 10, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "RSB"
    assert_includes result, "r10"
  end

  def test_and_imm
    word = VBlank::IR::Backends::GBA::ASM.and_imm(8, 8, 0xFF).unpack1("V")
    result = disasm(word)
    assert_includes result, "AND"
  end

  def test_orr_imm
    word = VBlank::IR::Backends::GBA::ASM.orr_imm(0, 0, 0x400).unpack1("V")
    result = disasm(word)
    assert_includes result, "ORR"
  end

  def test_mvn_imm
    word = VBlank::IR::Backends::GBA::ASM.mvn_imm(0, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "MVN"
  end

  # ========================================================================
  # Data processing — register
  # ========================================================================

  def test_add_reg
    word = VBlank::IR::Backends::GBA::ASM.add_reg(4, 4, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "ADD"
    assert_includes result, "r4"
    assert_includes result, "r2"
  end

  def test_sub_reg
    word = VBlank::IR::Backends::GBA::ASM.sub_reg(10, 10, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "SUB"
    assert_includes result, "r10"
    assert_includes result, "r11"
  end

  def test_cmp_reg
    word = VBlank::IR::Backends::GBA::ASM.cmp_reg(10, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "CMP"
    assert_includes result, "r10"
    assert_includes result, "r11"
  end

  def test_and_reg
    word = VBlank::IR::Backends::GBA::ASM.and_reg(11, 8, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "AND"
  end

  def test_eor_reg
    word = VBlank::IR::Backends::GBA::ASM.eor_reg(8, 8, 9).unpack1("V")
    result = disasm(word)
    assert_includes result, "EOR"
  end

  def test_mov_reg
    word = VBlank::IR::Backends::GBA::ASM.mov_reg(4, 3).unpack1("V")
    result = disasm(word)
    assert_includes result, "MOV"
    assert_includes result, "r4"
    assert_includes result, "r3"
  end

  def test_mvn_reg
    word = VBlank::IR::Backends::GBA::ASM.mvn_reg(8, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "MVN"
    assert_includes result, "r8"
  end

  # ========================================================================
  # Shifts
  # ========================================================================

  def test_lsl_imm
    word = VBlank::IR::Backends::GBA::ASM.lsl_imm(8, 8, 22).unpack1("V")
    result = disasm(word)
    assert_includes result, "LSL"
    assert_includes result, "r8"
    assert_includes result, "22"
  end

  def test_lsr_imm
    word = VBlank::IR::Backends::GBA::ASM.lsr_imm(8, 8, 22).unpack1("V")
    result = disasm(word)
    assert_includes result, "LSR"
    assert_includes result, "r8"
    assert_includes result, "22"
  end

  def test_asr_imm
    word = VBlank::IR::Backends::GBA::ASM.asr_imm(5, 5, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "ASR"
    assert_includes result, "r5"
    assert_includes result, "4"
  end

  # ========================================================================
  # Memory access
  # ========================================================================

  def test_ldr
    word = VBlank::IR::Backends::GBA::ASM.ldr(10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDR"
    assert_includes result, "r10"
    assert_includes result, "r12"
  end

  def test_str
    word = VBlank::IR::Backends::GBA::ASM.str(10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "STR"
    assert_includes result, "r10"
    assert_includes result, "r12"
  end

  def test_ldr_offset
    word = VBlank::IR::Backends::GBA::ASM.ldr_offset(3, 1, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDR"
    assert_includes result, "r3"
    assert_includes result, "0x8"
  end

  # The offset held in a register and scaled on the way in, which is how a table of words is
  # read by number. Read as an immediate offset it would print a number that is not there.
  def test_ldr_with_a_scaled_register_offset
    word = VBlank::IR::Backends::GBA::ASM.ldr_reg_lsl(12, 12, 0, 2).unpack1("V")
    assert_equal "LDR   r12, [r12, r0, LSL #2]", disasm(word).strip
  end

  def test_str_offset
    word = VBlank::IR::Backends::GBA::ASM.str_offset(0, 1, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "STR"
    assert_includes result, "r0"
    assert_includes result, "r1"
  end

  def test_ldrh
    word = VBlank::IR::Backends::GBA::ASM.load_halfword(1, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDRH"
    assert_includes result, "r1"
    assert_includes result, "r0"
  end

  def test_strh
    word = VBlank::IR::Backends::GBA::ASM.store_halfword(0, 1).unpack1("V")
    result = disasm(word)
    assert_includes result, "STRH"
    assert_includes result, "r0"
    assert_includes result, "r1"
  end

  # ========================================================================
  # Byte, halfword and post-indexed transfers
  # ========================================================================

  def test_ldrb_with_a_shifted_register_offset
    assert_equal "LDRB  r0, [r10, r8, LSR #16]", disasm(VBlank::IR::Backends::GBA::ASM.ldrb_reg_lsr(0, 10, 8, 16).unpack1("V"))
  end

  def test_ldrb_with_a_register_offset
    assert_equal "LDRB  r0, [r1, r2]", disasm(VBlank::IR::Backends::GBA::ASM.ldrb_reg(0, 1, 2).unpack1("V"))
  end

  def test_ldrb_with_an_immediate_offset
    assert_equal "LDRB  r0, [r1, #0x5]", disasm(VBlank::IR::Backends::GBA::ASM.ldrb_offset(0, 1, 5).unpack1("V"))
  end

  def test_strb_with_an_immediate_offset
    assert_equal "STRB  r0, [r1, #0x3]", disasm(VBlank::IR::Backends::GBA::ASM.strb_offset(0, 1, 3).unpack1("V"))
  end

  def test_strb_post_indexed
    assert_equal "STRB  r0, [r1], #0x1", disasm(VBlank::IR::Backends::GBA::ASM.strb_post(0, 1, 1).unpack1("V"))
  end

  def test_str_post_indexed
    assert_equal "STR   r0, [r1], #0x4", disasm(VBlank::IR::Backends::GBA::ASM.str_post(0, 1, 4).unpack1("V"))
  end

  def test_strh_with_an_offset
    assert_equal "STRH  r2, [r11, #0x2]  ; store 0x0 \u2192 [0x2]", disasm(VBlank::IR::Backends::GBA::ASM.store_halfword_offset(2, 11, 2).unpack1("V"))
    assert_equal "STRH  r2, [r11, #0x22]  ; store 0x0 \u2192 [0x22]", disasm(VBlank::IR::Backends::GBA::ASM.store_halfword_offset(2, 11, 0x22).unpack1("V"))
  end

  def test_strh_post_indexed
    assert_equal "STRH  r2, [r11], #0x2  ; store 0x0 \u2192 [0x0]", disasm(VBlank::IR::Backends::GBA::ASM.store_halfword_post(2, 11, 2).unpack1("V"))
  end

  def test_ldrh_with_an_offset
    assert_equal "LDRH  r1, [r0, #0x6]", disasm(VBlank::IR::Backends::GBA::ASM.load_halfword_offset(1, 0, 6).unpack1("V"))
  end

  def test_ldrsh_with_an_offset
    assert_equal "LDRSH  r1, [r0, #0x6]", disasm(VBlank::IR::Backends::GBA::ASM.ldrsh_offset(1, 0, 6).unpack1("V"))
  end

  def test_ldrsb_with_an_offset
    assert_equal "LDRSB  r1, [r0, #0x6]", disasm(VBlank::IR::Backends::GBA::ASM.ldrsb_offset(1, 0, 6).unpack1("V"))
  end

  # ========================================================================
  # Multiply
  # ========================================================================

  def test_mul
    word = VBlank::IR::Backends::GBA::ASM.mul(4, 5, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "MUL"
    assert_includes result, "r4"
    assert_includes result, "r5"
  end

  # ========================================================================
  # No ??? for anything we emit
  # ========================================================================

  def test_no_unknown_instructions_in_pong
    rom = VBlank.build("PONG", console: :gba, code: "BPNG", maker: "01", validate: false, out: nil, err: nil) do
      player_y = 0
      screen :bitmap
      state = 0
      scene :title do
        clear_screen :black
        draw_text "HI", 100, 76, :white
        state = 1 if pressed(:start)
      end
      scene :playing do
        clear_screen :blue
        player_y -= 2 if held(:up)
        player_y += 1
        player_y.clamp! 0, 136
        draw_rect_at 8, :player_y, 4, 24, :white
      end
      game_loop do
        call({ 0 => :title, 1 => :playing }, number: :state)
      end
    end

    inspector = VBlank::Diagnostics::Inspector.from_rom(rom)
    code = rom.buffer.byteslice(0xC0, rom.code_offset - 0xC0)
    words = code.unpack("V*")

    unknowns = words.reject { |w| w == 0 }.select do |w|
      desc, = inspector.disassemble(w, Array.new(16, 0))
      desc.start_with?("???")
    end

    assert_empty unknowns,
      "Inspector should decode all emitted instructions, but got ???: " \
      "#{unknowns.map { |w| '0x%08X' % w }}"
  end

  # ========================================================================
  # dump_func integration
  # ========================================================================

  def test_dump_func_prints_output
    out = StringIO.new
    VBlank.build("TEST", console: :gba, code: "BTST", maker: "01", validate: false, out: out, err: nil) do
      x = 0
      func :my_func do
        x = 42
      end
      dump_func :my_func
      halt
    end

    assert_includes out.string, "func :my_func"
    assert_includes out.string, "PUSH"
    assert_includes out.string, "POP"
  end

  def test_dump_func_works_with_scene_name
    out = StringIO.new
    VBlank.build("TEST", console: :gba, code: "BTST", maker: "01", validate: false, out: out, err: nil) do
      x = 0
      scene :title do
        x = 1
      end
      dump_func :title
      halt
    end

    assert_includes out.string, "_scene_title"
    assert_includes out.string, "PUSH"
  end

  # A routine kept in the console's quick memory keeps its big numbers in a table after its
  # return. Those words are numbers, and read as instructions they would come out as
  # nonsense that looks real — so the listing shows them as what they are.
  def test_dump_func_shows_a_number_table_as_numbers
    out = StringIO.new
    VBlank.build("TEST", console: :gba, validate: false, out: out, err: nil) do
      x = 0
      func(:my_func, fast: true) { x = 0x12345678 }
      dump_func :my_func
      game_loop { call :my_func }
    end

    listing = out.string.lines.map(&:strip)
    assert_includes listing.last, ".word 0x12345678"
    assert_match(/POP/, listing[-2], "the table comes straight after the routine's return")
  end

  # Each statement's instructions are listed under a line naming the statement and where the game
  # wrote it, the inner ones under theirs, so a reader of the listing can tell which line of the
  # game each instruction came from.
  def test_dump_func_groups_each_statement_under_the_line_that_wrote_it
    out = StringIO.new
    line = __LINE__ + 4
    VBlank.build("TEST", console: :gba, validate: false, out: out, err: nil) do
      x = 0
      func :counting do
        3.times { x += 1; x = x ^ 5 }
        x = 42
      end
      dump_func :counting
      halt
    end
    listing = out.string.lines.map(&:rstrip)
    heads = listing.select { |row| row.include?("; from ") }

    refute_empty heads, "the listing names the statements"
    assert_includes heads.join("\n"), "test_inspector.rb:#{line + 1}", "the line of `x = 42`"
    first_head = listing.index { |row| row.include?("; from ") }
    after_func_header = listing.index { |row| row.include?("=== func :counting") }
    assert_operator first_head, :>, after_func_header
    assert_match(/0x[0-9A-F]{4}: /, listing[first_head + 1], "an instruction comes straight after a statement's line")
  end

  def test_dump_func_warns_on_unknown
    err = StringIO.new
    VBlank.build("TEST", console: :gba, code: "BTST", maker: "01", validate: false, err: err) do
      dump_func :nonexistent
      halt
    end

    assert_includes err.string, "not found"
  end
end
