# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a sound driver's habits (`sound_driver`, Runtime::DriverWakes) cost the console's processor a
# frame on the Super Nintendo, measured in bsnes, against the same game whose driver names none.
#
# A retail driver keys its effects on its own processor, the SPC700, woken by its timer (fullsnes, "SNES
# APU SPC700 I/O Ports"), so no game of the console's own spends the main processor's time on this, and
# the budget is the work the habits add, written down: one more walk of the live effects each frame to
# give each effect asked for its wake, and a few instructions a wake to note which wakes hold a tick; with
# requests at rows, a second walk to note which were asked with no row, and each row's request asked
# for as the frame takes it up. A walk of two live effects is about a line of the frame.
class TestSNESSoundDriverCost < Minitest::Test
  Score = VBlank::Audio::Score

  FRAME_CLOCKS = 262 * 1364 # A frame's master clocks: 262 lines of 1364
  LINE_CLOCKS = 1364
  WAKES = Rational(8000, 0x60)
  ON_TICK_BUDGET = 3 * LINE_CLOCKS # The walk and the count of the wakes
  ROWS_BUDGET = 6 * LINE_CLOCKS # ...and the second walk and the rows asked for again

  private def effect(key)
    notes = [Score::Note.new(at: 0, key: key), Score::Note.new(at: 1, key: :C4), Score::Note.new(at: 2, key: :D4)]
    Score.new(tempo: 125, ticks_per_beat: 24, length: 4, plays_once: true, parts: [Score::Part.new(notes: notes)])
  end

  # Two effects asked for every 7 and 11 passes and a song, on a driver's interrupt, the driver described
  # by +driver+, each request at a row where +rows+.
  private def game(driver, rows)
    effects = { a: effect(:A5), b: effect(:E5) }
    tune = Score.new(tempo: 150, length: 96, parts: [Score::Part.new(plays: :noise, notes: [Score::Note.new(at: 0, key: :C4)])])
    VBlank.game("DRIVER COST", consoles: %i[snes]) do
      screen :bitmap
      enable_sound
      sound_driver interrupts_per_second: WAKES, **driver
      list = sound_effects :sfx, effects
      music = songs :music, [tune]
      count = var(:count, 0)
      game_loop do
        music.play 0, sent_after_rows: (40 if rows) if count == 5
        list.play :a, sent_after_rows: (200 if rows) if count % 7 == 3
        list.play :b, sent_after_rows: (20 if rows) if count % 11 == 6
        count.store! count + 1
        wait_vblank
      end
    end
  end

  # The master clocks a frame spent in the runtime's music and effects routines (SNESProfiler, each
  # label's share of the frames measured).
  private def sound_clocks(driver, rows: false)
    rom = game(driver, rows).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    readings = rom.profile(out: StringIO.new, settle: 10, frames: 600).runtime
    readings.select { |row| row.routine.to_s.match?(/\Art_(music|sfx|strikes)/) }.sum { |row| row.share * FRAME_CLOCKS }
  end

  def test_the_habits_cost_the_walks_they_add
    plain = sound_clocks({})
    on_tick = sound_clocks({ effects_start: :on_next_tick })
    at_rows = sound_clocks({ effects_start: :on_next_tick }, rows: true)

    assert_operator on_tick - plain, :<, ON_TICK_BUDGET, "on_next_tick costs #{(on_tick - plain).round} master clocks a frame more"
    assert_operator at_rows - plain, :<, ROWS_BUDGET, "rows cost #{(at_rows - plain).round} master clocks a frame more"
  end
end
