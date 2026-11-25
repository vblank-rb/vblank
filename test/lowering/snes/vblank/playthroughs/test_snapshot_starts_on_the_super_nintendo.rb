# frozen_string_literal: true

require "test_helper"
require "snapshot_start_tests"

# A comparison of two Super Nintendo cartridges started after a frame of its tape, from bsnes's own
# snapshot of each console, kept on disk.
class TestSnapshotStartsOnTheSuperNintendo < Minitest::Test
  include SnapshotStartTests

  private def console = :snes
end
