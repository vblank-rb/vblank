# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "ractor_workers"

# A snapshot is kept under the build of the emulator that wrote it: libmgba installed again, with the
# extension not rebuilt, is another build (Diagnostics::Emulator.advance_build names the library's own
# version and commit), and a snapshot the old one wrote is not read.
class TestSnapshotEmulatorBuild < Minitest::Test
  # Stands in for the emulator's build, which is the whole process's, so it cannot run beside tests
  # in other Ractors that make snapshots of their own.
  runs_on_the_main_ractor!

  include RactorWorkers

  # The stand-in answers another build on the main Ractor only, so a worker making a snapshot while
  # it is in place keys it as before.
  module AnotherBuild
    STAND_IN = Ractor.make_shareable(proc { Ractor.current == Ractor.main ? "another libmgba" : __real_advance_build })
  end

  private def walker
    VBlank.build("WALKER", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      box = sprite :box, at: [20, 60]
      game_loop { box.x += 1 if held(:right) }
    end
  end

  private def tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: WALKER 0x00000000\nstarts from: power-on\n\n40 right\n")

  def test_the_library_s_own_version_is_part_of_the_build
    assert_includes VBlank::Diagnostics::Emulator.advance_build, RubyGBAEmulator::MGBA_BUILD
  end

  def test_another_emulator_build_makes_a_snapshot_of_its_own
    rom = walker
    Dir.mktmpdir("vblank-snapshots") do |folder|
      snapshots = VBlank::Playthroughs::SnapshotCache.new(folder)
      tape.compare(rom, rom, starting_after: 20, snapshots: snapshots)
      result = while_swapped(VBlank::Diagnostics::Emulator, :advance_build, AnotherBuild::STAND_IN) do
        tape.compare(rom, rom, starting_after: 20, snapshots: snapshots)
      end

      assert_equal 2, Dir.glob(File.join(folder, "*.state")).size
      assert_equal [40, 20], result.frames_stepped, "the first side played to the start again"
    end
  end
end
