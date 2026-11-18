# frozen_string_literal: true

require "test_helper"
require "probe_write_tests"

# A probe writes a PlayStation program's memory, main RAM or the scratchpad, low byte first as the
# R3000 keeps a number, and saves and restores the console (Beetle PSX's own state).
class TestProbeWritesOnThePlayStation < Minitest::Test
  include ProbeWriteTests

  private def console = :ps1
end
