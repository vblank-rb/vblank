# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# `frames_since_power_on` on the Super Nintendo's cartridge, read back in bsnes. The games and what
# every console's cartridge is held to are in test/power_on_frame_games.rb.
class TestFramesSincePowerOnOnTheSuperNintendo < Minitest::Test
  include PowerOnFrameGames

  # The reading the screen-changing game waits for: past the frames the longest build sets up in,
  # the song's sounds sent to the sound chip and the spin after.
  GREEN_FROM_FRAME = 20

  # Spins before the loop that take a few frames.
  BUSY = 2_000

  # A painted screen's pass is copied to the console in the blank after it, so the frame that shows
  # the pass that read the hold is the one after the frame it ran in.
  PICTURE_FRAMES_LATER = 1

  def test_the_console_counts_the_frames_spent_setting_up
    assert_frames_setting_up_counted(:snes, busy: BUSY)
  end

  # Clearing the console's memories and sending the song's sounds to the sound chip take frames
  # before the game's first line. They are shown frames too.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    changed = green_frames(:snes, hold: GREEN_FROM_FRAME, busy: BUSY)

    assert_equal [GREEN_FROM_FRAME + 1 + PICTURE_FRAMES_LATER], changed.values.uniq,
                 "the frame each build's screen changed on, counted from power-on: #{changed}"
  end
end
