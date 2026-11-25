# frozen_string_literal: true

require "test_helper"
require "probe_snapshot_tests"

# A probe on a PlayStation program opened part way through a tape, from Beetle PSX's own snapshot of
# the console, kept on disk.
class TestProbeSnapshotsOnThePlayStation < Minitest::Test
  include ProbeSnapshotTests

  private def console = :ps1
end
