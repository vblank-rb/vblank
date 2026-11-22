# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# A comparison of two Genesis cartridges started after a frame of its tape, from Genesis Plus GX's own
# snapshot of each console. Its state leaves the battery-backed RAM out, so a cartridge that keeps a
# save is refused before anything plays.
class TestSnapshotStartsOnTheGenesis < Minitest::Test
  private def tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: BOX 0x00000000\nstarts from: power-on\n\n20 right\n")

  # A cartridge built here, written to a file whose header names battery-backed RAM, as Sega's header
  # lays it out: "RA" at 0x1B0.
  private def with_saving_cartridge(folder)
    rom = VBlank.build("BOX", console: :genesis, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      box = sprite :box, at: [20, 60]
      game_loop { box.x += 1 if held(:right) }
    end
    bytes = rom.buffer.dup
    bytes[0x1B0, 2] = "RA"
    path = File.join(folder, "saving.md")
    File.binwrite(path, bytes)
    yield path
  end

  def test_a_cartridge_that_keeps_a_save_is_refused_a_snapshot
    Dir.mktmpdir("vblank-snapshots") do |folder|
      snapshots = VBlank::Playthroughs::SnapshotCache.new(folder)
      with_saving_cartridge(folder) do |path|
        error = assert_raises(ArgumentError) { tape.compare(path, path, starting_after: 10, snapshots: snapshots) }

        assert_match "keeps a save", error.message
        assert_match "Genesis", error.message
      end
    end
  end
end
