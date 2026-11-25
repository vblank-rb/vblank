# frozen_string_literal: true

require "stringio"

# A cartridge profiled from power-on, with no frames run first (`rom.profile(settle: 0)`), and a
# tape's profile read from its first frame. Before the console runs its first instruction, the
# runtime has not yet cleared the words it counts passes in, so they hold whatever the console's
# memory held at power-on; a count taken from them goes below nought and wraps. Included by the
# profile test of each console whose profile counts passes; the including class names its console
# in `power_on_console`.
module PowerOnProfileTests
  # Frames measured: enough for several passes of a light game, few enough to stay quick.
  POWER_ON_FRAMES = 10

  def test_a_profile_from_power_on_counts_the_passes_the_interpreter_plays
    rom = power_on_game.build_rom(console: power_on_console, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: POWER_ON_FRAMES, settle: 0)

    played = VBlank::IR::Backends::Reference.new.run(power_on_game.program(console: power_on_console), frames: POWER_ON_FRAMES)[:passes]

    assert_equal played, result.passes
  end

  # A light game ends a pass a frame once it is going, and none while it sets up.
  def test_a_tape_read_from_power_on_ends_no_pass_below_nought
    rom = power_on_game.build_rom(console: power_on_console, out: StringIO.new, err: StringIO.new, profile: false)
    tape = VBlank::Playthroughs::Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: POWERON 0x00000000
      starts from: power-on

      #{POWER_ON_FRAMES} -
    TAPE
    readings = rom.profile(out: StringIO.new, tape: tape, frames: 1..4).readings

    assert_equal [1, 2, 3, 4], readings.map(&:frame)
    readings.each { |reading| assert_includes 0..1, reading.passes_ended, "frame #{reading.frame}" }
  end

  # A game whose loop counts its own passes, so the interpreter says how many it played.
  private def power_on_game
    VBlank.game("POWERON", consoles: [power_on_console]) do
      passes = 0
      game_loop { passes += 1 }
    end
  end
end
