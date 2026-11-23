# frozen_string_literal: true

require "test_helper"
require "stringio"

# Reading one or two controllers on the Super Nintendo, measured in bsnes, and the buttons a game
# sees from them still the interpreter's.
#
# The console reads both ports by itself as each vertical blank begins, when NMITIMEN's bit 0 is
# set: it clocks the sixteen bits of each controller into JOY1L to JOY2H ($4218-$421B) in about
# three lines, while the processor gets on with other work, and clears HVBJOY's bit 0 ($4212) when
# they are there (fullsnes, "SNES Controllers I/O Ports, Automatic Reading"; SNESdev wiki,
# "Controller reading"). The console's own games set that bit and take each controller with one
# load once the bit clears: Nintendo's MULTI5 routine reads the first controllers that way, and
# clocks a port by hand only for a Super Multitap's last two. So reading a controller costs a few
# instructions, and the budget here is that read with what this runtime adds to it: the buttons
# turned into IR::Buttons's order and what went down since the frame before kept.
class TestSNESControllerCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364
  LINE_CLOCKS = 1364

  # The console's own read is one load a controller. What this runtime adds to it, the buttons
  # turned into IR::Buttons's order through a table a byte at a time and what went down kept, is
  # about forty instructions more: under a line a controller, where clocking sixteen bits out of a
  # port by hand and testing each button took more than two and a half.
  BUDGET_A_CONTROLLER = LINE_CLOCKS

  def self.game(players)
    VBlank.game("PADS #{players}", consoles: %i[snes], players: players) do
      steps = (1..players).map { |player| var(:"steps#{player}", 0) }
      game_loop do
        steps.each.with_index(1) { |count, player| count.store!(count + 1) if held(:right, player: player) }
      end
    end
  end

  # The master clocks a frame spent in the runtime's routines that read or keep the buttons
  # (SNESProfiler, each label's share of the frames measured).
  private def button_clocks(players)
    rom = self.class.game(players).build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rows = rom.profile(out: StringIO.new, settle: 10, frames: 20).runtime
    rows.select { |row| row.routine.to_s.match?(/pad|buttons_now|buttons_remapped/) }.sum { |row| row.share * FRAME_CLOCKS }
  end

  [1, 2].each do |players|
    define_method(:"test_#{players}_controllers_cost_what_the_automatic_read_costs") do
      cost = button_clocks(players)

      assert_operator cost, :<, players * BUDGET_A_CONTROLLER,
                      "reading #{players} controllers costs #{cost.round} master clocks a frame"
    end
  end

  # Held and pressed, for both players, on passes of one frame.
  def test_two_players_held_and_pressed_agree_with_the_interpreter
    run = game_player.input_each_frame { |frame| two_player_presses(frame) }.run(two_player_game, frames: 24)

    assert_operator run[:held1], :>, 0
    assert_operator run[:held2], :>, 0
    assert_operator run[:taps1], :>, 1
    assert_operator run[:taps2], :>, 1
  end

  # A pass that takes several frames answers for a tap in any of them: the interrupt keeps the
  # buttons of every frame while the pass is still running.
  def test_a_tap_inside_a_long_pass_is_pressed
    run = game_player.input_each_frame { |frame| two_player_presses(frame) }.run(two_player_game(busy: true), frames: 24)

    assert_operator run[:taps1], :>, 0
    assert_operator run[:taps2], :>, 0
  end

  # Held from power-on: down on the first pass, as the interpreter's `hold` is.
  def test_a_button_held_from_power_on_is_held_on_the_first_pass
    run = game_player.hold(:right, :p2_right).run(two_player_game, frames: 4)

    assert_equal 4, run[:held1]
    assert_equal 4, run[:held2]
  end

  private

  # A tap of A on one frame in three for the first player, and of B on one in four for the
  # second; right held on every other frame by the first, and from the sixth by the second.
  def two_player_presses(frame)
    [(:a if (frame % 3).zero?), (:right if frame.even?), (:p2_b if (frame % 4) == 1), (:p2_right if frame > 5)].compact
  end

  def two_player_game(busy: false)
    VBlank.game("TWO PADS", consoles: %i[snes], players: 2) do
      held1 = var :held1, 0
      held2 = var :held2, 0
      taps1 = var :taps1, 0
      taps2 = var :taps2, 0
      work = var :work, 0
      game_loop do
        repeat(4000) { |i| work.store!(work + i) } if busy
        held1.store!(held1 + 1) if held(:right)
        held2.store!(held2 + 1) if held(:right, player: 2)
        taps1.store!(taps1 + 1) if pressed(:a)
        taps2.store!(taps2 + 1) if pressed(:b, player: 2)
      end
    end.program(console: :snes)
  end
end
