# frozen_string_literal: true

require "test_helper"
require "profile_build_notes_tests"

# A Super Nintendo cartridge's profile tells the hidden variables, the counted loops and the routine
# sizes the Advance's and the Color's tell.
class TestSNESProfileBuildNotes < Minitest::Test
  include ProfileBuildNotesTests

  def test_the_routine_sizes_are_counted_against_the_cartridges_kilobytes
    rom = notes_rom

    assert_match(/^In all: \d+ bytes of routines, in a cartridge of #{rom.size / 1024} KB\.$/, human_profile(rom))
  end

  private def console = :snes
end
