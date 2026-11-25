# frozen_string_literal: true

require "test_helper"
require "profile_build_notes_tests"

# A PlayStation program's profile tells the hidden variables, the counted loops and the routine
# sizes the Advance's and the Color's tell.
class TestPS1ProfileBuildNotes < Minitest::Test
  include ProfileBuildNotesTests

  private def console = :ps1
end
