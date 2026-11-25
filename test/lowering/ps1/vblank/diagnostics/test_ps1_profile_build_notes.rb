# frozen_string_literal: true

require "test_helper"
require "profile_build_notes_tests"

# A PlayStation program's profile tells the hidden variables, the counted loops and the routine
# sizes the Advance's and the Color's tell.
class TestPS1ProfileBuildNotes < Minitest::Test
  include ProfileBuildNotesTests

  def test_the_routine_sizes_are_counted_against_the_programs_kilobytes
    exe = notes_rom

    assert_match(/^In all: \d+ bytes of routines, in a program of #{exe.size / 1024} KB\.$/, human_profile(exe))
  end

  private def console = :ps1
end
