# frozen_string_literal: true

require "test_helper"

# FAIL_FAST=1 stops a run at its first failing test, and says which.
class TestFailFast < Minitest::Test
  # A result as a reporter is given one: this many failures, and whether it was skipped.
  Result = Data.define(:failed, :skip) do
    def passed? = !failed && !skip
    def skipped? = skip
    def to_s = "TestThing#test_it"
  end

  private def stops_for(result)
    io = StringIO.new
    stopped = []
    VBlank::Testing::FailFast.new(io, stop: -> { stopped << true }).record(result)
    [stopped.size, io.string]
  end

  def test_a_failure_stops_the_run_and_is_printed
    stops, said = stops_for(Result.new(failed: true, skip: false))

    assert_equal 1, stops
    assert_match(/TestThing#test_it/, said)
  end

  def test_a_pass_or_a_skip_goes_on
    assert_equal [0, ""], stops_for(Result.new(failed: false, skip: false))
    assert_equal [0, ""], stops_for(Result.new(failed: false, skip: true))
  end
end
