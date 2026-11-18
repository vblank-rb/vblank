# frozen_string_literal: true

require "test_helper"
require "probe_write_tests"

# A probe writes an Advance cartridge's memory, low byte first as the ARM keeps a number, and saves
# and restores the console (libmgba's own state): the answer key the other consoles' tests share.
class TestProbeWrites < Minitest::Test
  include ProbeWriteTests

  private def console = :gba
end
