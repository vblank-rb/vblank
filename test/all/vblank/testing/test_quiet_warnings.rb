# frozen_string_literal: true

require "test_helper"
require "vblank/testing/quiet_warnings"

# The one warning a test's game cannot help is left out of a run, and no other.
class TestQuietWarnings < Minitest::Test
  Quiet = VBlank::Testing::QuietWarnings

  def test_an_unused_variable_in_a_test_file_is_left_out
    assert Quiet.noise?("/repo/test/all/test_thing.rb:12: warning: assigned but unused variable - state\n")
  end

  def test_the_same_warning_in_the_library_stays
    refute Quiet.noise?("/repo/lib/vblank/thing.rb:12: warning: assigned but unused variable - state\n")
  end

  def test_any_other_warning_in_a_test_file_stays
    refute Quiet.noise?("/repo/test/all/test_thing.rb:12: warning: method redefined; discarding old thing\n")
  end
end
