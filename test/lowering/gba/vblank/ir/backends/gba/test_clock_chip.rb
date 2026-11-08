# frozen_string_literal: true

require "test_helper"

require "stringio"

# THE CARTRIDGE READS ITS CLOCK CHIP. A cartridge that carries a clock has a small chip with a
# watch battery of its own, reached through three of four pins the cartridge brings out: the
# console clocks a command into it a bit at a time and clocks the date and time back out the same
# way. The first reading of the time after each wait for the screen reads it, and every reading
# reads that copy.
#
# The emulator gives a cartridge a clock only when told (RubyGBAEmulator::Probe#clock_at), pinned
# to a moment and moved on a console frame each frame, so what these read is the same every run —
# and the same as the interpreter reads, started at the same moment.
class TestClockChip < Minitest::Test
  include EmulatorSupport

  READINGS = VBlank::IR::Clock::READINGS
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)

  def setup
    require_emulator!
  end

  # A game that keeps every reading of the clock in a variable of the same name, every pass.
  private def rom
    VBlank.build("CLOCK", console: :gba, out: StringIO.new, err: StringIO.new, profile: false) do
      screen :bitmap
      now = clock
      kept = READINGS.to_h { |name| [name, var(name, -1)] }
      game_loop do
        kept[:hour] = now.hour
        kept[:minute] = now.minute
        kept[:second] = now.second
        kept[:year] = now.year
        kept[:month] = now.month
        kept[:day] = now.day
        kept[:weekday] = now.weekday
        kept[:present] = 0
        kept[:present] = 1 if now.present?
        kept[:set] = 0
        kept[:set] = 1 if now.set?
      end
    end
  end

  private def console_readings(verifier) = READINGS.to_h { |name| [name, verifier.var(name)] }

  private def console_of(**how)
    built = rom
    VBlank::Diagnostics::Verifier.new(built, vars: built.built.var_addresses, **how)
  end

  def test_the_cartridge_reads_the_clock_chip
    v = console_of(frames: 10, clock: THURSDAY)

    assert_equal({ hour: 21, minute: 7, second: 5, year: 2026, month: 10, day: 22, weekday: 4, present: 1, set: 1 },
                 console_readings(v))
  end

  # A CHIP WHOSE BATTERY RAN OUT: there, never set, and every reading 0. It starts counting the
  # hours 1 to 12, as such a chip does, so this is also where the cartridge telling it to count in
  # 24 hours is held to working — the chip says it is there only once that has been done.
  def test_a_chip_whose_battery_ran_out_is_there_and_not_set
    v = console_of(frames: 10, clock: THURSDAY, clock_set: false)

    assert_equal READINGS.to_h { |name| [name, name == :present ? 1 : 0] }, console_readings(v)
  end

  def test_a_cartridge_with_no_clock_chip_is_told_so
    v = console_of(frames: 10)

    assert_equal READINGS.to_h { |name| [name, 0] }, console_readings(v)
  end

  # FRAME BY FRAME THE SAME AS THE INTERPRETER, through midnight on new year's eve: the cartridge's
  # readings pass after pass are the interpreter's, from the pass where the console's start-up
  # frames have gone by. Started half a second before the second turns, so neither run reads a
  # second turn over within the frames the console spends starting up.
  def test_the_cartridge_reads_what_the_interpreter_reads_into_the_new_year
    start = Time.new(2026, 12, 31, 23, 59, Rational(585, 10))
    interpreted = []
    player = Reference.new.clock_at(start)
    player.each_vblank { interpreted << READINGS.to_h { |name| [name, player[name]] } }
    player.run(rom.built.source_program, frames: 150)

    v = console_of(frames: 1, clock: start)
    console = [console_readings(v)] + Array.new(152) { console_readings(v.step) }
    # The chip and the console's frames both start counting at power-on, and so do the interpreter's
    # clock and its frames, so the two line up with no frames between them.
    same = console.first(interpreted.size) == interpreted

    assert same, "the cartridge's readings, pass by pass, are the interpreter's: " \
                 "#{console.map { |r| r.values_at(:minute, :second) }.uniq.inspect} against " \
                 "#{interpreted.map { |r| r.values_at(:minute, :second) }.uniq.inspect}"
    assert_equal 2027, interpreted.last[:year], "the run reaches the new year"
  end

  # --- setting it -----------------------------------------------------------------

  SATURDAY = { year: 2031, month: 5, day: 17, hour: 8, minute: 9, second: 10 }.freeze

  # A game that sets the clock on its third pass, and otherwise keeps every reading as the one above.
  private def setting_rom(set_on_pass: 2)
    VBlank.build("SETCLOCK", console: :gba, out: StringIO.new, err: StringIO.new, profile: false) do
      screen :bitmap
      now = clock
      var :hour_at_power_on, now.hour
      before_the_loop = var :hour_before_the_loop, -1
      before_the_loop = now.hour
      passes = 0
      kept = READINGS.to_h { |name| [name, var(name, -1)] }
      game_loop do
        now.set_to(**SATURDAY) if passes == set_on_pass
        kept[:hour] = now.hour
        kept[:minute] = now.minute
        kept[:second] = now.second
        kept[:year] = now.year
        kept[:month] = now.month
        kept[:day] = now.day
        kept[:weekday] = now.weekday
        kept[:present] = 0
        kept[:present] = 1 if now.present?
        kept[:set] = 0
        kept[:set] = 1 if now.set?
        passes += 1
      end
    end
  end

  # THE CHIP IS NEVER WRITTEN — the emulator would keep its own time whatever it was told — so
  # the cartridge keeps how far the time set is from the chip's and adds it on. Pass by pass that
  # is what the interpreter reads, the second turning over on the same frame, for a chip that
  # was set before and one whose battery ran out.
  def test_a_cartridge_that_sets_the_clock_reads_what_the_interpreter_reads
    built = setting_rom
    [true, false].each do |was_set|
      interpreted = []
      player = Reference.new.clock_at(THURSDAY, set: was_set)
      player.each_vblank { interpreted << READINGS.to_h { |name| [name, player[name]] } }
      player.run(built.built.source_program, frames: 90)

      v = VBlank::Diagnostics::Verifier.new(built, frames: 1, vars: built.built.var_addresses,
                                             clock: THURSDAY, clock_set: was_set)
      console = [console_readings(v)] + Array.new(89) { console_readings(v.step) }

      # Compared as one yes or no, with the readings in the message: a failing comparison of two
      # long lists works out its difference in a way a test played in a Ractor cannot.
      same = console == interpreted

      assert same, "a chip #{was_set ? "set" : "never set"} reads what the interpreter reads: " \
                   "#{console.map { |r| r.values_at(:hour, :second, :set) }.uniq.inspect} against " \
                   "#{interpreted.map { |r| r.values_at(:hour, :second, :set) }.uniq.inspect}"
      assert_equal SATURDAY.merge(weekday: 6, second: 11, present: 1, set: 1), console.last
    end
  end

  # THE TIME SET IS THERE AT THE NEXT POWER-ON, from the save memory: switched off an hour, the
  # cartridge reads the time set an hour on — read as it starts up, before the save has been read
  # back, the chip's own time, as the interpreter does; and read before the game loop, once it
  # has, the time set, though the chip has not been read again in between.
  def test_the_time_set_comes_back_after_the_power_goes_off
    built = setting_rom
    first = VBlank::Diagnostics::Verifier.new(built, frames: 30, vars: built.built.var_addresses, clock: THURSDAY)
    first.pixel(0, 0)
    reader = setting_rom(set_on_pass: -1)
    back = VBlank::Diagnostics::Verifier.new(reader, frames: 2, vars: reader.built.var_addresses,
                                              clock: THURSDAY + 3600 + 1, save: first.save_image)

    assert_equal [9, 9, 11], console_readings(back).values_at(:hour, :minute, :second)
    assert_equal [22, 9], [back.var(:hour_at_power_on), back.var(:hour_before_the_loop)]
  end

  # WHAT READING THE CHIP COSTS A PASS: a command of eight bits out, seven bytes of eight back,
  # each bit a few writes to the pins and a read, and each byte's two digits made a number. That
  # comes to about a thousand instructions, a few of a frame's lines run from the cartridge — and
  # once a pass however many readings the game makes.
  MOST_A_PASS = 1200

  # A game that asks the time only while a button is held.
  private def asking_rom
    VBlank.build("ASKING", console: :gba, out: StringIO.new, err: StringIO.new, profile: false) do
      screen :bitmap
      now = clock
      hour = var :hour, -1
      game_loop do
        hour = now.hour if held(:a)
      end
    end
  end

  private def chip_work(**how)
    result = VBlank::Diagnostics::Profiler.run(asking_rom, frames: 30, picture: false, clock: THURSDAY, **how)
    VBlank::Diagnostics::Profiler.work_in(result).fetch(:__clock_chip_receive, 0)
  end

  # Most passes of most games ask nothing of the clock, so the chip is asked by the first reading of
  # a pass, and a pass with none does not talk to it at all.
  def test_a_pass_that_reads_no_time_does_not_talk_to_the_chip
    assert_equal 0, chip_work
    assert_operator chip_work(keys: [:a]), :>, 0, "a pass that reads the time still does"
  end

  # The reading is the pass's own, however late in it the game asks.
  def test_a_reading_asked_for_late_in_the_game_is_the_time_now
    built = asking_rom
    v = VBlank::Diagnostics::Verifier.new(built, frames: 10, vars: built.built.var_addresses, clock: THURSDAY, keys: [:a])

    assert_equal 21, v.var(:hour)
  end

  def test_reading_the_chip_costs_about_a_thousand_instructions_a_pass
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false, clock: THURSDAY)
    chip = %i[each_pass send receive].sum do |part|
      VBlank::Diagnostics::Profiler.work_in(result).fetch(:"__clock_chip_#{part}", 0)
    end

    assert_operator chip, :>, 0, "the chip is read"
    assert_operator chip, :<, MOST_A_PASS, "reading the chip costs #{chip} instructions a pass"
  end
end
