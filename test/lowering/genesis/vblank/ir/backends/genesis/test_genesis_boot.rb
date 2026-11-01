# frozen_string_literal: true

require "test_helper"

# A cartridge made of the assembler's code, the Linker's image and GenesisROM's header and vectors plays
# in the emulator: the processor starts at the reset vector, and what it writes to the colour memory is
# the picture.
class TestGenesisBoot < Minitest::Test
  M68000 = VBlank::IR::Backends::Genesis::M68000
  Linker = VBlank::IR::Backends::Genesis::Linker
  H = VBlank::Console::GenesisHardware

  # A colour of 6 red, 3 green and 1 blue, each of the console's three bits, in its own layout.
  COLOUR = 0x026C

  private def cartridge(colour)
    asm = M68000.new("boot")
    asm.label("reset")
    [[H::REG_MODE1, H::MODE1_NORMAL], [H::REG_MODE2, H::MODE2_SCREEN_ON], [H::REG_BACKDROP, 0], [H::REG_MODE4, H::MODE4_40_CELLS],
     [H::REG_INCREMENT, H::INCREMENT_WORD]].each do |register, value|
      asm.move(:w, asm.imm(H::VDP_REGISTER | (register << 8) | value), asm.abs_l(H::VDP_CONTROL))
    end
    asm.move(:l, asm.imm(H.command(H::WRITE_CRAM, 0)), asm.abs_l(H::VDP_CONTROL))
    asm.move(:w, asm.imm(colour), asm.abs_l(H::VDP_DATA))
    asm.label("forever")
    asm.bra("forever")
    linked = Linker.new([asm.section]).link
    VBlank::Cartridge::GenesisROM.new(linked.image, title: "BOOT", vectors: { reset: linked.address_of("reset") })
  end

  private def picture_of(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "boot.gen")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_genesis(path)
      3.times { core.run_frame }
      [core.colors.uniq, core.registers.fetch(:pc)]
    ensure
      core&.destroy
    end
  end

  def test_the_backdrop_is_the_colour_the_cartridge_wrote
    colours, pc = picture_of(cartridge(COLOUR))

    assert_equal [0b001_011_110], colours, "red in the low three bits, then green, then blue"
    assert_includes 0x200..0x260, pc, "the processor is looping where the code is"
  end

  def test_a_cartridge_whose_vectors_name_no_other_place_restarts_at_reset_on_a_fault
    rom = cartridge(COLOUR)

    assert_equal rom.bytes.byteslice(0x04, 4), rom.bytes.byteslice(0x0C, 4), "the address error vector is reset's"
  end
end
