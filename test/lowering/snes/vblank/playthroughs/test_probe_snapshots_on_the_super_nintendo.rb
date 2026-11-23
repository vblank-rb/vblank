# frozen_string_literal: true

require "test_helper"
require "probe_snapshot_tests"

# A probe on a Super Nintendo cartridge opened part way through a tape, from bsnes's own snapshot of
# the console, kept on disk.
class TestProbeSnapshotsOnTheSuperNintendo < Minitest::Test
  include ProbeSnapshotTests

  private def console = :snes
end
