# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE KEYBOARD AS THE GAME'S BUTTONS, in DOSBox, held to the interpreter pass for pass (DOS::CheckedRun):
# the keys are pressed on the emulated keyboard, reach the program through its keyboard interrupt, and
# every variable of every pass must agree with the interpreter playing the same buttons.
class TestDOSKeyboard < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # LEFT for three frames, then A as well for two, then nothing, then B for one, then a tap of START one
  # frame long.
  FRAMES = { 3 => [:left], 4 => [:left], 5 => [:left], 6 => %i[left a], 7 => %i[left a], 9 => [:b], 11 => [:start] }.freeze

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)

  private def counting_buttons
    program_of do
      screen :bitmap
      held_frames = var :held_frames, 0
      presses = var :presses, 0
      lefts = var :lefts, 0
      starts = var :starts, 0
      game_loop do
        held_frames += 1 if held(:any)
        presses += 1 if pressed(:any)
        lefts += 1 if held(:left)
        starts += 1 if pressed(:start)
      end
    end
  end

  def test_keys_going_down_and_up_are_held_and_pressed_as_the_interpreter_counts_them
    played = DOS::CheckedRun.new.input_each_frame { |frame| FRAMES.fetch(frame, []) }.run(counting_buttons, frames: 14)

    assert_equal [7, 4, 5, 1], [played[:held_frames], played[:presses], played[:lefts], played[:starts]]
  end

  # Every button the keyboard has, each on a frame of its own: each is one press, and the game tells them apart.
  def test_every_button_the_keyboard_has_reaches_the_game_as_itself
    buttons = VBlank::Console::DOS.buttons
    program = program_of do
      screen :bitmap
      seen = var :seen, 0
      game_loop do
        buttons.each_with_index { |button, bit| seen |= (1 << bit) if pressed(button) }
      end
    end
    played = DOS::CheckedRun.new.input_each_frame { |frame| frame.even? ? [buttons[(frame / 2) - 1]].compact : [] }
                            .run(program, frames: (buttons.size * 2) + 4)

    assert_equal (1 << buttons.size) - 1, played[:seen]
  end

  # A button down as the power comes on is held through the first pass and is one press, however long it stays down.
  def test_a_button_held_from_power_on_is_held_at_once_and_is_one_press
    program = program_of do
      screen :bitmap
      x = var :x, 40
      presses = var :presses, 0
      game_loop do
        x += 1 if held(:right)
        presses += 1 if pressed(:right)
      end
    end
    played = DOS::CheckedRun.new.hold(:right).run(program, frames: 6)

    assert_equal [46, 1], [played[:x], played[:presses]]
  end

  # A button down at power-on and let go before the first pass ends was never down on a frame the game
  # read, so it is no press.
  def test_a_button_let_go_before_the_first_pass_ends_is_no_press
    played = DOS::CheckedRun.new.hold(:a).input_each_frame { [] }.run(counting_buttons, frames: 5)

    assert_equal [0, 0], [played[:held_frames], played[:presses]]
  end

  # A PASS OF MORE THAN ONE FRAME. The work in it takes the pass past a retrace, which the program cannot
  # see while it works: the timer says how many frames went by, the interpreter is told the same, and a tap
  # one frame long is one press whichever of the pass's frames it lands on.
  SLOW_FRAMES = { 4 => [:a], 7 => [:b], 8 => [:b], 11 => [:left] }.freeze

  def test_a_slow_pass_counts_its_frames_and_loses_no_tap
    program = program_of do
      screen :bitmap
      presses = var :presses, 0
      work = var :work, 0
      game_loop do
        presses += 1 if pressed(:any)
        repeat(SLOW_WORK) { work += 1 }
      end
    end
    run = DOS::CheckedRun.new.input_each_frame { |frame| SLOW_FRAMES.fetch(frame, []) }
    played = run.run(program, frames: 8)

    assert_equal 3, played[:presses]
    assert_operator run.frames_took(3), :>, 1, "the pass was meant to take more than a frame"
  end

  # Enough turns of a small loop to take a pass past one retrace and not past three.
  SLOW_WORK = 30_000

  # Any player's button is the one player's: `player: :any` builds and reads the keyboard.
  def test_any_player_s_button_is_the_keyboard_s
    program = program_of do
      screen :bitmap
      lefts = var :lefts, 0
      game_loop { lefts += 1 if held(:left, player: :any) }
    end
    played = DOS::CheckedRun.new.hold(:left).run(program, frames: 4)

    assert_equal 4, played[:lefts]
  end

  # Pause sends three bytes, of which the second reads as Ctrl (the A button): none of them is a button.
  def test_pause_is_no_button
    exe = DOS.new.build(counting_buttons)
    Dir.mktmpdir("dos-keyboard") do |dir|
      path = File.join(dir, "GAME.EXE")
      exe.write(path)
      core = VBlank::Diagnostics::Emulator.open_dos(path)
      10.times { core.run_frame }
      core.press(%i[pause])
      5.times { core.run_frame }
      core.press([])
      5.times { core.run_frame }
      core.press(%i[ctrl])
      5.times { core.run_frame }
      presses = VBlank::Diagnostics::DOSMemory.read32(core, exe.built.variables.fetch(:presses))

      assert_equal 1, presses, "Ctrl after it is one press, so the keyboard was heard and Pause was none"
    ensure
      core&.destroy
    end
  end
end
