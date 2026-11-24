# frozen_string_literal: true

require "test_helper"
require "stringio"

# An Advance cartridge that rumbles (`rumble`, GBA::Rumble): the game notes the pattern, and the
# screen's interrupt runs the motor a frame at a time from pin 3 of the cartridge's port. The
# emulator reports the motor as the cartridge sets it, frame for frame as the interpreter's motor runs.
class TestGBARumble < Minitest::Test
  PRESS = 20

  # A game that rumbles on the pass that sees A pressed, and halts on the pass that sees B.
  private def bumper(frames: 10, pattern: "##..#.#.", halts: false)
    VBlank.build("BUMPER", console: :gba, err: StringIO.new, out: StringIO.new) do
      screen :tiled, backdrop: :black
      hits = var :hits, 0
      game_loop do
        if pressed(:a)
          rumble frames: frames, pattern: pattern
          hits += 1
        end
        halt if halts && pressed(:b)
      end
    end
  end

  # The motor on each frame from power-on, as "#" and ".", +button+ held on frame PRESS.
  private def felt(rom, button: :a, frames: PRESS + 40)
    key = VBlank::Console::Hardware.const_get(:"KEY_#{button.upcase}")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, keys: ->(played) { played + 1 == PRESS ? key : 0 })
    Array.new(frames) { v.step.motor_on? ? "#" : "." }.join
  end

  def test_the_motor_runs_the_pattern_for_the_frames_said
    felt = felt(bumper)

    assert_includes felt, "##..#.#.##", "the pattern, then round again for the ten frames"
    assert_equal "##..#.#.##", felt[/#.*#/], "and then still"
  end

  def test_the_cartridge_says_it_carries_a_motor_only_when_the_game_rumbles
    plain = VBlank.build("PLAIN", console: :gba, err: StringIO.new, out: StringIO.new) do
      screen :tiled, backdrop: :black
      game_loop { nil }
    end

    assert_includes bumper.buffer, VBlank::IR::Backends::GBA::Rumble::MARK
    refute_includes plain.buffer, VBlank::IR::Backends::GBA::Rumble::MARK
    refute_includes felt(plain), "#"
  end

  def test_the_motor_runs_as_the_interpreter_runs_it
    program = Builder.new.tap do |b|
      b.instance_eval do
        screen :tiled, backdrop: :black
        pass = var :pass, 0
        game_loop do
          pass += 1
          rumble frames: 10, pattern: "##..#.#." if pass == 2
        end
      end
      b.finalize_program
    end.program
    player = VBlank::IR::Backends::Reference.new
    seen = +""
    player.each_vblank { seen << (player.motor_on? ? "#" : ".") }.run(program, frames: 16)

    rom = VBlank.build("BUMPER", console: :gba, err: StringIO.new, out: StringIO.new) do
      screen :tiled, backdrop: :black
      pass = var :pass, 0
      game_loop do
        pass += 1
        rumble frames: 10, pattern: "##..#.#." if pass == 2
      end
    end
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0)
    cartridge = Array.new(16) { v.step.motor_on? ? "#" : "." }.join

    # The cartridge's first frame goes to setting up, before its first pass; the interpreter has no
    # such frame, so its motor is that much early.
    assert_equal ".#{seen[0...-1]}", cartridge
    assert_includes cartridge, "#"
  end

  def test_a_game_that_halts_shakes_nothing_more
    felt = felt(bumper(frames: 1000, halts: true), button: :a, frames: PRESS + 5)
    assert_includes felt, "#"

    rom = bumper(frames: 1000, halts: true)
    both = VBlank::Console::Hardware::KEY_A | VBlank::Console::Hardware::KEY_B
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, keys: ->(played) { played + 1 == PRESS ? both : 0 })
    after = Array.new(40) { v.step.motor_on? ? "#" : "." }.join

    refute_includes after[PRESS + 2..], "#"
  end

  # The clock chip talks on pins 0 to 2 of the same port and the motor is pin 3 (GBATEK, "GBA
  # Cart Real-Time Clock", "GBA Cart Rumble"), so a game reads the clock and rumbles on one
  # cartridge: each pass reads the time while the motor runs its pattern.
  def test_a_game_reads_the_clock_while_the_motor_runs
    rom = VBlank.build("BOTH", console: :gba, err: StringIO.new, out: StringIO.new) do
      screen :tiled, backdrop: :black
      now = clock
      hour = var :hour, -1
      second = var :second, -1
      game_loop do
        hour = now.hour
        second = now.second
        rumble frames: 10, pattern: "##..#.#." if pressed(:a)
      end
    end
    key = VBlank::Console::Hardware::KEY_A
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.built.var_addresses,
                                               clock: Time.new(2026, 10, 22, 21, 7, 5),
                                               keys: ->(played) { played + 1 == PRESS ? key : 0 })
    felt = Array.new(PRESS + 40) { v.step.motor_on? ? "#" : "." }.join
  
    assert_equal "##..#.#.##", felt[/#.*#/], "the motor runs the pattern for the ten frames"
    assert_equal 21, v.var(:hour), "the clock reads right beside it"
    assert_operator v.var(:second), :>=, 5
  end
end
