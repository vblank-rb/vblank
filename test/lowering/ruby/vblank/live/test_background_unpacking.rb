# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# A SHELL'S UNPACKING PLAYED IN A RACTOR OF ITS OWN (Live::BackgroundUnpacking). On the Ruby run
# alone: it plays the unpacking as Ruby whatever run it is in.
class TestBackgroundUnpacking < Minitest::Test
  BackgroundUnpacking = VBlank::Live::BackgroundUnpacking
  NAMES = VBlank::Original::ShellFacts::UnpackingNames.new(bytes: "bytes", finished: "finished", fault_kind: "fault_kind")

  # An unpacking whose game cannot be made stops with the error it stopped with in its Ractor: its
  # class, its words, and the line of the unpacking's Ruby it came from.
  def test_an_unpacking_that_fails_in_its_ractor_raises_what_failed
    failed = assert_raises(TypeError) { BackgroundUnpacking.new("raise TypeError, 'the routine broke'", "", NAMES) }

    assert_match "the routine broke", failed.message
    assert_match "(the game, as Ruby):1", failed.backtrace.first
  end

  # Running out of stack in the Ractor is said as itself. Ruby keeps one error for it, already
  # caused by another, and raising it as the Ractor's cause made a circle of causes Ruby refused.
  def test_an_unpacking_that_runs_out_of_stack_says_so
    failed = assert_raises(SystemStackError) { BackgroundUnpacking.new("def self.deeper(n) = deeper(n + 1) + 1\ndeeper(0)", "", NAMES) }

    assert_match "stack level too deep", failed.message
  end
end
