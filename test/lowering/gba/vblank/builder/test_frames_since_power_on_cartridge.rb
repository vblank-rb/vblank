# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# `frames_since_power_on` on the Advance's cartridge, read back in the emulator. The games and what
# every console's cartridge is held to are in test/power_on_frame_games.rb.
class TestFramesSincePowerOnCartridge < Minitest::Test
  include PowerOnFrameGames

  # The reading the screen-changing game waits for.
  GREEN_FROM_FRAME = 10

  def test_the_console_counts_the_frames_spent_setting_up
    assert_frames_setting_up_counted(:gba, busy: 30_000)
  end

  # A SONG WITH A RECORDED PART starts the sound mixer at power-on, and the mixer takes most of a
  # frame to find its footing before the screen's interrupt is armed. Those frames are shown too.
  def test_the_frames_the_mixer_takes_to_start_are_counted
    frame, read = first_pass_frame_and_reading(:gba, screen_waiting_game(hold: GREEN_FROM_FRAME, song: true))

    assert_equal frame - 1, read, "a game playing a recording reads the frames before its first pass"
  end

  # A screen held until a frame since power-on changes on that frame whatever the cartridge holds:
  # no song, a song played on a recording, a long wait before the game loop, with a song or without,
  # and a song beside a routine kept in the quick memory.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    changed = green_frames(:gba, hold: GREEN_FROM_FRAME, busy: 30_000)
    changed["a song and a routine in the quick memory"] =
      first_green_frame(:gba, screen_waiting_game(hold: GREEN_FROM_FRAME, song: true, quick_lines: 1000), GREEN_FROM_FRAME)

    assert_equal [GREEN_FROM_FRAME + 1], changed.values.uniq,
                 "the frame each build's screen changed on, counted from power-on: #{changed}"
  end
end
