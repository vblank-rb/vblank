# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# `frames_since_power_on` on the PlayStation's program, read back in Beetle PSX. The games and what
# every console's cartridge is held to are in test/power_on_frame_games.rb.
#
# A PROGRAM IS COPIED IN BEFORE IT STARTS. A PlayStation program is loaded into RAM before its first
# instruction runs (by the BIOS from a disc, by Beetle's own loader here), and a longer program takes
# longer to copy: a game with a song, or with a big table and nothing else added, starts a frame later
# in the emulator than the same game without. Those frames are before the program and no program can
# count them. So the builds of the screen-waiting game all carry the song, the ones that do not play
# it too, and are held to changing on the same frame as each other. The first test, of a small
# program, holds the count to the emulator's frames themselves.
class TestFramesSincePowerOnOnThePlayStation < Minitest::Test
  include PowerOnFrameGames

  # The reading the screen-changing game waits for.
  GREEN_FROM_FRAME = 10

  # Spins before the loop that take several frames.
  BUSY = 300_000

  def test_the_console_counts_the_frames_spent_setting_up
    assert_frames_setting_up_counted(:ps1, busy: BUSY)
  end

  # Sending the song's sounds to the sound chip, and spinning, take frames before the game's first
  # pass. They are shown frames too.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    changed = green_frames(:ps1, hold: GREEN_FROM_FRAME, busy: BUSY, songs_in_every_build: true)

    assert_equal 1, changed.values.uniq.size, "the frame each build's screen changed on, counted from power-on: #{changed}"
  end
end
