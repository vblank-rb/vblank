# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A GAME PAUSED FROM A SCRIPT is held a frame at a time. Played by a person a pause sleeps until the
# window has an event (runtime/rg_pause.h, tested as arithmetic in test_native_pause.rb); a script has
# no events to wake it, and each time round the pause reads the next line of it, so the wait must stay
# a frame long or a run of a given number of lines stops taking the time it did. The game does not move
# for any of them.
class TestNativePausedFromAScript < Minitest::Test
  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  FRAME_SECONDS = 280_896.0 / 16_777_216

  GAME = VBlank.game("PAUSEDSCRIPT", consoles: %i[gba]) do
    screen :bitmap
    frames = var :frames, 0
    game_loop { frames += 1 }
  end

  # A pause begun after 5 frames and ended after +paused+ more lines of the script, in a run of 30
  # game frames, and what the game counted.
  private def play(paused:)
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(GAME, File.join(dir, "game"), err: nil)
      lines = ["0"] * 5 + ["0 hotkey:pause"] + ["0"] * (paused - 1) + ["0 hotkey:pause"]
      script = (lines + ["0"] * 40).map { |line| "#{line}\n" }.join
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "30", "--settings-file",
                                             File.join(dir, "none.txt"), stdin_data: script)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_predicate status, :success?, said
      [took, Native::HeadlessRun.variables_in(printed.lines.map(&:chomp)).fetch(:frames)]
    end
  end

  def test_each_line_of_a_script_in_a_pause_takes_a_frame_and_the_game_does_not_move
    short_time, short_frames = play(paused: 2)
    long_time, long_frames = play(paused: 62)

    assert_equal short_frames, long_frames, "the game does not move while it is paused, however long"
    assert_in_delta 60 * FRAME_SECONDS, long_time - short_time, 0.25, "sixty more lines in the pause are sixty more frames of time"
  end
end
