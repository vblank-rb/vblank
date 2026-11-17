# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE GAME'S BUSIEST NUMBERS IN THE DIRECT PAGE. A 65816 instruction naming a byte of the direct
# page takes one byte of address and one cycle less than one naming a 16-bit address (the WDC
# 65816 data sheet's cycle table; fullsnes, "CPU Timings"), and the console's own games keep the
# numbers their loops work on there. The build keeps the variables a game names most, counted by
# where they are named and how deep in loops, in the room the direct page has after the runtime's
# own working numbers (SNES::Lowering#place_variables, Backends::VariableUse).
#
# A routine called once a pass works a few numbers in a loop of 64 turns, against the same loop
# of 32, so the two differ by 32 turns and nothing else. A game crowded with numbers it names once
# a pass besides keeps the loop's in the direct page all the same.
class TestSNESDirectPageVariablesCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Numbers the crowded game names once a pass each: more than the direct page holds.
  CROWD = 80

  # The game whose loop goes round +turns+ times a pass, with +crowd+ other numbers.
  def self.game(turns, crowd: 0)
    VBlank.game("DIRECT #{turns} #{crowd}", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      crowd.times { |k| var :"crowd_#{k}", k }
      a = 0
      b = 3
      c = 0
      func(:work) do
        repeat(turns) do
          a += b
          c = a - c
          b = c & 7
        end
      end
      game_loop do
        call :work
        crowd.times { |k| clamp! :"crowd_#{k}", 0, 1000 }
      end
    end
  end

  private def awake_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  private def clocks_a_turn(crowd)
    more = awake_share(self.class.game(64, crowd: crowd))
    fewer = awake_share(self.class.game(32, crowd: crowd))
    (more - fewer) * FRAME_CLOCKS / 32
  end

  # Measured: a turn was 637 master clocks with the three numbers at 16-bit addresses, crowded or
  # not; on the direct page, 544. What is left is the numbers worked in 32 bits.
  def test_a_turn_working_three_numbers_costs_under_570_master_clocks
    cost = clocks_a_turn(0)
    assert_operator cost, :<, 570, "a turn costs #{cost.round(1)} master clocks"
  end

  def test_a_turn_in_a_crowded_game_costs_under_570_master_clocks
    cost = clocks_a_turn(CROWD)
    assert_operator cost, :<, 570, "a turn costs #{cost.round(1)} master clocks"
  end

  # The numbers are the interpreter's on every pass, the crowded game's too.
  def test_the_crowded_game_is_the_interpreters_on_every_pass
    game_player.run(self.class.game(32, crowd: CROWD).program(console: :snes), frames: 10)
  end
end
