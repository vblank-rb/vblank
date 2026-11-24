# frozen_string_literal: true

require "test_helper"
require "tape_snapshot_tests"

# A tape played on a Super Nintendo cartridge, and a film's side, started part way through the tape
# from bsnes's own snapshot of the console, kept on disk.
class TestTapeSnapshotsOnTheSuperNintendo < Minitest::Test
  include TapeSnapshotTests

  private def console = :snes
end
