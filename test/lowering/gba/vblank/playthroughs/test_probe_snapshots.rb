# frozen_string_literal: true

require "test_helper"
require "probe_snapshot_tests"

# A probe on an Advance cartridge opened part way through a tape, from libmgba's own snapshot of the
# console, kept on disk.
class TestProbeSnapshots < Minitest::Test
  include ProbeSnapshotTests

  private def console = :gba
end
