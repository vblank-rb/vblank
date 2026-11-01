# frozen_string_literal: true

require "test_helper"

# `dump_func` on the Color: the machine code a routine was made into, in the processor's own
# words, with the game's variables and the runtime's routines by name.
class TestSM83Listing < Minitest::Test
  Listing = VBlank::Diagnostics::SM83Listing

  # A hand-checked instruction of each shape, so the words come from the processor's manual and
  # not from the table that decodes them.
  INSTRUCTIONS = { [0x00] => "nop", [0x76] => "halt", [0xC9] => "ret", [0xD8] => "ret c",
                   [0x3E, 0x07] => "ld a,$07", [0x78] => "ld a,b", [0x70] => "ld [hl],b",
                   [0x21, 0x34, 0x12] => "ld hl,$1234", [0x2A] => "ld a,[hl+]", [0x32] => "ld [hl-],a",
                   [0xFA, 0x00, 0xC1] => "ld a,[$C100]", [0xEA, 0x00, 0xC1] => "ld [$C100],a",
                   [0xF0, 0x44] => "ldh a,[$FF44]", [0xE0, 0x40] => "ldh [$FF40],a",
                   [0x80] => "add a,b", [0xC6, 0x01] => "add a,$01", [0xFE, 0x20] => "cp $20", [0xAF] => "xor a",
                   [0x3C] => "inc a", [0x23] => "inc hl", [0x0B] => "dec bc", [0x09] => "add hl,bc",
                   [0xC5] => "push bc", [0xF1] => "pop af", [0xCD, 0x00, 0x20] => "call $2000",
                   [0xC2, 0x00, 0x40] => "jp nz,$4000", [0xE9] => "jp hl", [0x20, 0xFE] => "jr nz,$0100",
                   [0x18, 0x02] => "jr $0104", [0xCB, 0x7F] => "bit 7,a", [0xCB, 0x37] => "swap a",
                   [0xCB, 0x86] => "res 0,[hl]", [0xCB, 0x11] => "rl c", [0xE8, 0xFC] => "add sp,-4",
                   [0xD3] => "db $D3" }.freeze

  def test_each_shape_of_instruction_reads_as_the_processor_says_it
    INSTRUCTIONS.each do |bytes, words|
      said, length = Listing.decode(bytes.pack("C*"), 0, 0x100)

      assert_equal words, said, bytes.inspect
      assert_equal bytes.length, length, words
    end
  end

  private def listing_of(name)
    out = StringIO.new
    err = StringIO.new
    VBlank.build("LISTING", console: :gbc, out: out, err: err) do
      flag = var :flag, 0, width: :byte
      score = var :score, 0
      func(:tick) do
        score = score * 300_000
        score += 1 if flag == 2
      end
      dump_func name
      game_loop do
        call :tick
        wait_vblank
      end
    end
    [out.string, err.string]
  end

  def test_a_routine_lists_its_code_with_variables_and_runtime_routines_by_name
    listed, = listing_of(:tick)

    assert_match(/=== func :tick/, listed)
    assert_match(/ld a,\[flag\]/, listed, "a variable by its name")
    assert_match(/cp \$02/, listed)
    assert_match(/call rt_\w+/, listed, "a runtime routine by its label")
    assert_match(/\bret\b/, listed)
  end

  # The numbers a routine keeps after its return are numbers, and read as code they look real.
  def test_a_number_kept_beside_the_code_is_shown_as_a_number
    listed, = listing_of(:tick)

    assert_match(/\.long 300000/, listed)
  end

  def test_a_routine_that_is_not_there_says_so
    _, said = listing_of(:nowhere)

    assert_match(/:nowhere not found/, said)
  end
end
