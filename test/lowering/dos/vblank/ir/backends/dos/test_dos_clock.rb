# frozen_string_literal: true

require "test_helper"

# THE DATE AND TIME ON A PC, read and set by the game, in DOSBox and held to the interpreter pass for pass
# (DOS::CheckedRun). The test says what the PC's clock chip reads as the program starts; the program reads
# the chip once and counts on by its frames, as the interpreter counts.
class TestDOSClock < Minitest::Test
  DOS = VBlank::IR::Backends::DOS
  TIME = VBlank::IR::Clock::TIME

  # A Thursday evening a second before the minute turns...
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 59)
  # ...and a Saturday morning five years on, as a game sets it.
  SATURDAY = { year: 2031, month: 5, day: 17, hour: 8, minute: 9, second: 10 }.freeze

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)

  # A game that keeps every reading of the clock in a variable of that name, and what it is asked.
  private def reading_program(set_to: nil, set_on_pass: 3)
    program_of do
      screen :bitmap
      now = clock
      passes = 0
      present = var :present, -1
      set = var :set, -1
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      game_loop do
        now.set_to(**set_to) if set_to && passes == set_on_pass
        readings[:hour] = now.hour
        readings[:minute] = now.minute
        readings[:second] = now.second
        readings[:year] = now.year
        readings[:month] = now.month
        readings[:day] = now.day
        readings[:weekday] = now.weekday
        present = 0
        present = 1 if now.present?
        set = 0
        set = 1 if now.set?
        passes += 1
      end
    end
  end

  private def read(run) = TIME.to_h { |name| [name, run[name]] }

  def test_the_game_reads_the_date_and_time_the_chip_holds
    run = DOS::CheckedRun.new.clock_at(THURSDAY).run(reading_program, frames: 3)

    assert_equal({ hour: 21, minute: 7, second: 59, year: 2026, month: 10, day: 22, weekday: 4 }, read(run))
    assert_equal [1, 1], [run[:present], run[:set]]
  end

  # A second is seventy frames and a little: by then the second, and the minute with it, has turned.
  def test_the_clock_moves_on_by_the_frames_the_game_shows
    run = DOS::CheckedRun.new.clock_at(THURSDAY).run(reading_program, frames: 75)

    assert_equal [21, 8, 0], [run[:hour], run[:minute], run[:second]]
  end

  # The last second of a leap day in a leap year the hundreds rule keeps: the next is the first of March.
  def test_midnight_turns_the_day_the_month_and_the_weekday
    run = DOS::CheckedRun.new.clock_at(Time.new(2000, 2, 29, 23, 59, 59)).run(reading_program, frames: 75)

    assert_equal({ hour: 0, minute: 0, second: 0, year: 2000, month: 3, day: 1, weekday: 3 }, read(run))
  end

  # The chip holds whole seconds and its year in two registers: a time given with part of a second is read
  # as the second it shows, and a year past 2099 as itself.
  def test_a_part_of_a_second_and_a_later_century_are_read_alike_on_both_sides
    run = DOS::CheckedRun.new.clock_at(Time.new(2100, 1, 1, 0, 0, 59.9)).run(reading_program, frames: 10)

    assert_equal [2100, 59], [run[:year], run[:second]]
  end

  # A clock whose battery ran out is there and was never set: every reading is nought.
  def test_a_clock_never_set_is_there_and_reads_zeros
    run = DOS::CheckedRun.new.clock_at(Time.new(2000, 1, 1, 5), set: false).run(reading_program, frames: 2)

    assert_equal [1, 0], [run[:present], run[:set]]
    assert_equal [0], read(run).values.uniq
  end

  # A PC always has a clock, so a run told no time still reads one, and the same one on both sides.
  def test_a_run_told_no_time_reads_a_clock_all_the_same
    run = DOS::CheckedRun.new.run(reading_program, frames: 2)

    assert_equal [1, 1, 2000], [run[:present], run[:set], run[:year]]
  end

  def test_setting_the_clock_reads_the_time_set_at_once
    run = DOS::CheckedRun.new.clock_at(THURSDAY).run(reading_program(set_to: SATURDAY), frames: 4)

    assert_equal SATURDAY.merge(weekday: 6), read(run)
  end

  # From there it keeps time: a hundred and fifty frames on is two seconds and a little.
  def test_a_clock_set_moves_on_from_the_time_set
    run = DOS::CheckedRun.new.clock_at(THURSDAY).run(reading_program(set_to: SATURDAY), frames: 154)

    assert_equal 12, run[:second]
  end

  def test_setting_a_clock_never_set_makes_it_set
    never = Time.new(2000, 1, 1, 5)
    before = DOS::CheckedRun.new.clock_at(never, set: false).run(reading_program(set_to: SATURDAY), frames: 3)
    after = DOS::CheckedRun.new.clock_at(never, set: false).run(reading_program(set_to: SATURDAY), frames: 4)

    assert_equal [0, 1], [before[:set], after[:set]]
    assert_equal SATURDAY.merge(weekday: 6), read(after)
  end

  # The time set is kept in the game's save, so it is there the next time the game is switched on.
  def test_a_time_set_is_there_after_the_power_goes_off_and_on
    save = VBlank::IR::SaveImage.new
    game = reading_program(set_to: SATURDAY)
    DOS::CheckedRun.new(save: save).clock_at(THURSDAY).run(game, frames: 5)
    # The same game, read before the pass on which it sets the clock again.
    again = DOS::CheckedRun.new(save: save).clock_at(THURSDAY).run(game, frames: 2)

    assert_equal SATURDAY.merge(weekday: 6), read(again)
  end
end
