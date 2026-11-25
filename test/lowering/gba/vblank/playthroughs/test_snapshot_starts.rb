# frozen_string_literal: true

require "test_helper"
require "snapshot_start_tests"

# A comparison of two Advance cartridges started after a frame of its tape, from libmgba's own
# snapshot of each console, kept on disk.
class TestSnapshotStarts < Minitest::Test
  include SnapshotStartTests

  private def console = :gba
end
