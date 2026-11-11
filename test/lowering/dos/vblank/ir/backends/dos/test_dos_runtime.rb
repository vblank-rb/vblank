# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE RUNTIME AS A PLAYER MEETS IT: the program started by its name alone, with no reader holding it at
# its start, waits for no gate and keeps time by the card's retrace, one pass a frame.
class TestDOSRuntime < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  private def counting_game
    VBlank.game("DOSGAME", consoles: %i[dos]) do
      screen :bitmap
      passes = var :passes, 0
      game_loop { passes += 1 }
    end.program(console: :dos)
  end

  def test_a_program_started_plainly_runs_without_waiting_at_the_gate
    exe = DOS.new.build(counting_game)
    Dir.mktmpdir("dos-runtime") do |dir|
      path = File.join(dir, "GAME.EXE")
      exe.write(path)
      probe = VBlank::Diagnostics::DOSProbe.new(path, hold: false)
      probe.step(10)
      started = probe.read32(exe.built.variables.fetch(:passes))
      probe.step(50)
      passes = probe.read32(exe.built.variables.fetch(:passes)) - started

      assert_operator started, :>, 0, "the game made no pass in its first 10 frames"
      assert_equal 50, passes, "a frame is one retrace, and a pass waits for one: one pass a frame, none lost or doubled"
    ensure
      probe&.close
    end
  end
end
