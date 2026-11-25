# frozen_string_literal: true

require "test_helper"
require "profile_build_notes_tests"

# A Super Nintendo cartridge's profile tells the hidden variables, the counted loops and the routine
# sizes the Advance's and the Color's tell.
class TestSNESProfileBuildNotes < Minitest::Test
  include ProfileBuildNotesTests

  private def console = :snes
end
