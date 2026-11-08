# frozen_string_literal: true

require "test_helper"

require "conformance_fixture"

# The coverage guard on the Advance's lowering: the kitchen-sink fixture lowers to a clean
# cartridge, and raw bytes go into it verbatim. That the fixture covers every kind is in
# test/all/vblank/ir/test_cross_backend_conformance.rb.
class TestCrossBackendConformanceCartridge < Minitest::Test
  ROMValidator = VBlank::Cartridge::ROMValidator

  def test_gba_backend_lowers_the_whole_fixture_to_a_clean_rom
    # A feature the GBA backend can't lower raises LoweringError; a structurally
    # bad ROM makes ROM.assemble (which validates the image) raise ROMError.
    # Neither may happen.
    code = GBA.new.lower(ConformanceFixture.program)
    rom = ROM.assemble(code, title: "CONFORM", code: "BCNF", maker: "01")

    assert ROMValidator.check(rom).ok?, "the lowered fixture must be a valid ROM"
  end

  # ---- the one hardware-only exception, pinned explicitly ----

  def test_raw_lowers_on_the_gba_backend
    nop = [0xE1A00000].pack("V")
    code = GBA.new.lower(VBlank::IR::Build.program(
      VBlank::IR::Build.screen(:bitmap),
      VBlank::IR::Build.raw(nop),
      VBlank::IR::Build.halt,
    ))
    assert_includes code, nop, "the GBA backend appends raw bytes verbatim"
  end
end
