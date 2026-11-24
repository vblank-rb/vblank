# frozen_string_literal: true

require "test_helper"
require "tape_snapshot_tests"

# A tape played on a Genesis cartridge, and a film's side, started part way through the tape from
# Genesis Plus GX's own snapshot of the console, kept on disk.
class TestTapeSnapshotsOnTheGenesis < Minitest::Test
  include TapeSnapshotTests

  private def console = :genesis
end
