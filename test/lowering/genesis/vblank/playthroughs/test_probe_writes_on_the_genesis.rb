# frozen_string_literal: true

require "test_helper"
require "probe_write_tests"

# A probe writes a Genesis cartridge's work RAM, high byte first as the 68000 keeps a number, and
# saves and restores the console (Genesis Plus GX's own state).
class TestProbeWritesOnTheGenesis < Minitest::Test
  include ProbeWriteTests

  private def console = :genesis
end
