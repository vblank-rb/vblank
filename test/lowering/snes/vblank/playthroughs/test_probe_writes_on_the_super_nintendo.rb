# frozen_string_literal: true

require "test_helper"
require "probe_write_tests"

# A probe writes a Super Nintendo cartridge's work RAM, low byte first as the 65816 keeps a number,
# and saves and restores the console (bsnes's own state).
class TestProbeWritesOnTheSuperNintendo < Minitest::Test
  include ProbeWriteTests

  private def console = :snes
end
