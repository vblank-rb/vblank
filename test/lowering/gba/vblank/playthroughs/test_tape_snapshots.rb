# frozen_string_literal: true

require "test_helper"
require "tape_snapshot_tests"

# A tape played on an Advance cartridge, and a film's side, started part way through the tape from
# libmgba's own snapshot of the console, kept on disk.
class TestTapeSnapshots < Minitest::Test
  include TapeSnapshotTests

  private def console = :gba
end
