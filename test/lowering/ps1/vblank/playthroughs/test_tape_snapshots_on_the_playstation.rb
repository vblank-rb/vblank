# frozen_string_literal: true

require "test_helper"
require "tape_snapshot_tests"

# A tape played on a PlayStation program, and a film's side, started part way through the tape from
# Beetle PSX's own snapshot of the console, kept on disk.
class TestTapeSnapshotsOnThePlayStation < Minitest::Test
  include TapeSnapshotTests

  private def console = :ps1
end
