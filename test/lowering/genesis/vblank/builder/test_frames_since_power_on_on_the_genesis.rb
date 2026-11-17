# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# `frames_since_power_on` on the Genesis's cartridge, read back in Genesis Plus GX. The games and what
# every console's cartridge is held to are in test/power_on_frame_games.rb.
class TestFramesSincePowerOnOnTheGenesis < Minitest::Test
  include PowerOnFrameGames

  # The reading the screen-changing game waits for: past the frames the longest build sets up in,
  # the console's memories cleared, its painted screen copied whole, and the spin after.
  GREEN_FROM_FRAME = 30

  # Spins before the loop that take a few frames.
  BUSY = 3_000

  # A painted screen's pass is copied to the console in the blank after it, so the frame that shows
  # the pass that read the hold is the one after the frame it ran in.
  PICTURE_FRAMES_LATER = 1

  def test_the_console_counts_the_frames_spent_setting_up
    assert_frames_setting_up_counted(:genesis, busy: BUSY)
  end

  # The frame a game's first pass is seen on, from power-on: setting up clears the video chip's memory
  # with its own fill while the processor clears work RAM (Runtime::Boot). Cleared a long word at a
  # time through the data port, then work RAM a long word a turn, it was frame 9 for a small game and
  # 11 for one of 700 numbers and 40 lists. The fill is the longer of the two, and with neither clear
  # at all the first pass is seen on frames 3 and 4: the clearing costs one frame.
  SMALL_GAME_FIRST_PASS_FRAME = 4
  BIG_GAME_FIRST_PASS_FRAME = 5

  def test_a_small_game_shows_its_first_pass_early
    frame, reading = first_pass_frame_and_reading(:genesis, declaring_game(2, 2))

    assert_equal SMALL_GAME_FIRST_PASS_FRAME, frame
    assert_equal frame - 1, reading, "the first pass reads the frames shown before it"
  end

  def test_a_game_of_many_numbers_and_lists_shows_its_first_pass_early
    frame, reading = first_pass_frame_and_reading(:genesis, declaring_game(700, 40))

    assert_equal BIG_GAME_FIRST_PASS_FRAME, frame
    assert_equal frame - 1, reading, "the first pass reads the frames shown before it"
  end

  # Clearing the console's memories takes frames before the game's first line, and copying its
  # painted screen whole more before its first pass is shown. They are shown frames too.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    changed = green_frames(:genesis, hold: GREEN_FROM_FRAME, busy: BUSY)

    assert_equal [GREEN_FROM_FRAME + 1 + PICTURE_FRAMES_LATER], changed.values.uniq,
                 "the frame each build's screen changed on, counted from power-on: #{changed}"
  end
end
