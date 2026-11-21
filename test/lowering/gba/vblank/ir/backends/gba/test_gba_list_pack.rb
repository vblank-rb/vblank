# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_list_packing"

# A list's items written into a list of bytes on the Advance's cartridge, which copies the run as
# one block where both lists are plain arrays (GBA::Lists#emit_list_pack) and writes a ring's items
# out as the loops the step stands for. Read off the running cartridge, the bytes list holds what
# the interpreter's does.
class TestGBAListPack < Minitest::Test
  include ListPackingPrograms

  def setup
    require_emulator!
  end

  def test_each_case_on_the_cartridge_holds_what_the_interpreter_holds
    CASES.each do |name, (width, items, at, ring)|
      program = packed(width, items, at, ring)
      rom = assemble_rom(program, name: "LISTPACK")
      cartridge = VBlank::Diagnostics::Verifier.new(rom, frames: 2, vars: rom.var_addresses)

      assert_equal Reference.new.run(program, frames: 2).list(:bytes), cartridge.list(:bytes), "the #{name} case"
      assert_equal 0, cartridge.var(:count), "the #{name} case leaves its count at nought"
    end
  end
end
