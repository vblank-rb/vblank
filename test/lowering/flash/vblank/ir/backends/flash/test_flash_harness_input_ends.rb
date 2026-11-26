# frozen_string_literal: true

require "test_helper"
require "open3"
require "timeout"

# The harness ends when whoever plays the game goes: standard input closed, or standard output with nobody reading
# it, and does not play on for thousands of frames.
class TestFlashHarnessInputEnds < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  def setup
    game = VBlank.game("small", consoles: %i[gba]) do
      game_loop { clear_screen :black }
    end
    @swf = Flash.new.build_headless(VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new))
    @harness = VBlank::Diagnostics::FlashPlayer.harness_path
  end

  def test_the_end_of_input_ends_the_run
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, complaint, status = Open3.capture3(@harness, @swf, "--headless", "100000", stdin_data: "0\n0\n")
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute status.success?
    assert_includes complaint, "standard input ended"
    assert_operator took, :<, 10
  end

  def test_nobody_reading_the_output_ends_the_run
    reader, writer = IO.pipe
    reader.close
    pid = Process.spawn(@harness, @swf, "--headless", "100000", in: File::NULL, out: writer, err: File::NULL)
    writer.close
    _, status = Timeout.timeout(20) { Process.wait2(pid) }

    refute status.success?
  end
end
