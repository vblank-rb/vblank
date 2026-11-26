# frozen_string_literal: true

require "test_helper"

# A sound driver on the Super Nintendo counts its tempo on a timer of the sound unit, and the timers
# divide the sound unit's own clock. That clock runs nearer 32040 samples a second than the 32000 its
# output is named for (the SNESdev wiki, "S-SMP"; fullsnes, "SNES APU"), so a driver's interrupts come
# that much more often than the rate read from it. Over a long run the effects' notes fall on the
# frames the faster clock gives, which a clock of exactly 8000 counts over 0x60 puts a frame later or
# earlier.
#
# The answer key is the driver's interrupts in real time: interrupt k at k over the rate, in the frame
# that time falls in, each adding the driver's tempo step to a count of 16 bits, a tick where it comes
# round. An effect starts on the first interrupt of the frame it is taken up on, and a tick on that same
# interrupt does not move it on.
class TestSoundEffectOnTimerOnTheSuperNintendo < Minitest::Test
  Score = VBlank::Audio::Score

  NOMINAL = Rational(8000, 0x60) # a sound unit timer's interrupts a second, as the driver names them
  SOUND_UNIT_HZ = 32_040         # the sound unit's samples a second, measured (bsnes apuFrequency)
  NAMED_HZ = 32_000              # ...and as its output is named
  TICK_RATE = 50                 # the effect's ticks a second: a tempo of 125 at 24 ticks a beat
  NOTE_TICKS = [0, 3, 5, 8, 10].freeze
  FRAMES = 1200
  ASKED_EVERY = 40
  ASKED_ON = 7

  private def game
    notes = NOTE_TICKS.each_with_index.map { |at, n| Score::Note.new(at: at, key: n.even? ? :A5 : :E5) }
    effect = Score.new(tempo: 125, ticks_per_beat: 24, length: 20, plays_once: true, on_timer: true,
                       interrupts_per_second: NOMINAL, parts: [Score::Part.new(notes: notes)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: effect }
      count = var(:count, 0)
      game_loop do
        list.play :chime if count % ASKED_EVERY == ASKED_ON
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = :snes }
  end

  # The frame each of the effect's notes sounds on, from the log of +player+: a pitch of nought is its end.
  private def note_frames(player, program)
    frames = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| frames << frame if entry.first == :note && entry[1] == :"sfx.chime" && entry[2].positive? }
      logged = player.audio.size
    end
    player.run(program, frames: FRAMES)
    frames
  end

  # The frames the notes fall on with the sound unit's timer interrupting +rate+ times a second.
  private def predicted(rate)
    frame_seconds = VBlank::Console::SUPER_NINTENDO.frame_seconds
    step = (Rational(TICK_RATE) / NOMINAL * 65_536).floor # the driver's own tempo add, read from it
    count = 0
    ticks = []
    (1..).each do |k|
      frame = (Rational(k) / (rate * frame_seconds)).ceil
      break if frame > FRAMES

      first_in_frame = (Rational(k - 1) / (rate * frame_seconds)).ceil < frame
      count += step
      next if count < 65_536

      count -= 65_536
      ticks << [frame, first_in_frame]
    end
    (ASKED_ON...FRAMES).step(ASKED_EVERY).flat_map do |asked|
      start = asked + 2 # the first frame the player can take the ask up on
      own = [start] + ticks.reject { |frame, first| frame < start || (frame == start && first) }.map(&:first)
      NOTE_TICKS.filter_map { |tick| own[tick] }
    end
  end

  def test_the_effects_notes_fall_where_the_sound_units_own_clock_puts_them
    program = game
    note_frames(game_player, program)
    heard = note_frames(Reference.new, program)
    real = predicted(NOMINAL * Rational(SOUND_UNIT_HZ, NAMED_HZ))
    named = predicted(NOMINAL)
    apart = real.each_index.find { |i| real[i] != named[i] }

    refute_nil apart, "the two clocks put some note on different frames"
    assert_equal real[apart], heard[apart], "note #{apart} on the sound unit's clock, not #{named[apart]}"
    assert_equal real, heard
  end
end
