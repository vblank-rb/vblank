# frozen_string_literal: true

require "test_helper"
require "multitap_file_tests"

# A Super Nintendo cartridge file played with a Super Multitap in its second port, and compared
# with itself on a tape (MultitapFileComparisonTests). And `multitap:` refused where a console has
# no such adapter, or where the probe is handed a built cartridge.
class TestMultitapFileOnTheSuperNintendo < Minitest::Test
  include MultitapFileComparisonTests

  private def cartridge_console = :snes

  def test_a_multitap_is_refused_on_a_console_with_none
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "wanderers.gba")
      Wanderers.build_rom(console: :gba, out: StringIO.new, err: StringIO.new).write(path)

      error = assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(path, multitap: true) }
      assert_match "Game Boy Advance", error.message
      assert_match "multitap:", error.message
    end
  end

  def test_a_multitap_is_refused_for_a_built_cartridge
    built = Wanderers.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

    error = assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(built, multitap: true) }
    assert_match "cartridge file", error.message
  end
end
