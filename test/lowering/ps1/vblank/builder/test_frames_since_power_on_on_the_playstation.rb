# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# `frames_since_power_on` on the PlayStation's program, read back in Beetle PSX. The games and what
# every console's cartridge is held to are in test/power_on_frame_games.rb.
#
# A program is copied in before it starts. A PlayStation program is loaded into RAM before its first
# instruction runs: by the BIOS from a disc on a console, which takes seconds, and by Beetle's own
# loader here, which reads it from the expansion port, a longer program taking longer. Those frames
# are before the program and no program can count them, so frames from power-on are no PlayStation
# measure: the count is held to the screen's blanks since the program's first instruction, as the
# emulator says when that ran (power_on_frame_games' first_pass_seen). The builds of the screen-waiting game
# all carry the song, the ones that do not play it too, and are held to changing on the same frame as
# each other.
class TestFramesSincePowerOnOnThePlayStation < Minitest::Test
  include PowerOnFrameGames

  # The reading the screen-changing game waits for.
  GREEN_FROM_FRAME = 10

  # Spins before the loop that take several frames.
  BUSY = 300_000

  def test_the_console_counts_the_frames_spent_setting_up
    assert_frames_setting_up_counted(:ps1, busy: BUSY)
  end

  # A program long enough that the loader is still copying it after the first frame: an unread table
  # of 8000 words makes it 44K. Its first pass reads the blanks since it began, not since power-on.
  def test_a_long_program_counts_from_its_first_instruction
    seen = first_pass_seen(:ps1, long_program(8000))

    assert_operator seen.blanks_before_program, :>, 1, "the loader should still be copying after the first frame"
    assert_equal seen.due, seen.reading
  end

  private

  # A counting game (`passes`, and `first` read on the first pass) that keeps a table of +words+ words.
  def long_program(words)
    b = Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :black
      kept = table :kept, Array.new(words) { |n| ((n * 7) % 100) + 1 }, width: :word
      passes = 0
      first = -1
      read = 0
      game_loop do
        first = frames_since_power_on if passes.zero?
        passes += 1
        read = kept[passes % 4]
      end
    end
    b.finalize_program
    b.program
  end

  # Sending the song's sounds to the sound chip, and spinning, take frames before the game's first
  # pass. They are shown frames too.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    changed = green_frames(:ps1, hold: GREEN_FROM_FRAME, busy: BUSY, songs_in_every_build: true)

    assert_equal 1, changed.values.uniq.size, "the frame each build's screen changed on, counted from power-on: #{changed}"
  end
end
