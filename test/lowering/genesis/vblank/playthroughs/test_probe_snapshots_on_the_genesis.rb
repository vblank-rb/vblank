# frozen_string_literal: true

require "test_helper"
require "probe_snapshot_tests"

# A probe on a Genesis cartridge opened part way through a tape, from Genesis Plus GX's own snapshot
# of the console, kept on disk. Its refusal of a cartridge that keeps a save is beside the
# comparison's, in test_snapshot_starts_on_the_genesis.rb.
class TestProbeSnapshotsOnTheGenesis < Minitest::Test
  include ProbeSnapshotTests

  private def console = :genesis
end
