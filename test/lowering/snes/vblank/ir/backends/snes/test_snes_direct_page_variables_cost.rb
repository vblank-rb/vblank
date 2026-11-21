# frozen_string_literal: true

require "test_helper"
require "stringio"

# The game's busiest numbers in the direct page. A 65816 instruction naming a byte of the direct
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

  # The game whose loop goes round +turns+ times a pass, with +crowd+ other numbers, and with
  # +touching+ a test each pass of whether two sprites' drawn pixels touch.
  def self.game(turns, crowd: 0, touching: false)
    VBlank.game("DIRECT #{turns} #{crowd}#{' TOUCHING' if touching}", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      crowd_vars = Array.new(crowd) { |k| var :"crowd_#{k}", k }
      if touching
        image(:dot, "." => :transparent, "o" => :red) { "........\n...oo...\n...oo...\n........\n" }
        ring = sprite :dot, at: [100, 50]
        dart = sprite :dot, at: [60, 50]
        touches = var :touches, 0
      end
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
        crowd_vars.each { |held| held.clamp! 0, 1000 }
        touches += 1 if touching && ring.overlaps?(dart)
      end
    end
  end

  # The runtime's scratch for whether drawn pixels touch (Runtime::Collide) is on the direct page only
  # in a game that asks: it is two pictures' masks, sizes and the box they share, 52 bytes, room for
  # thirteen of the game's numbers or more.
  COLLIDE_SCRATCH_BYTES = 52

  def test_a_game_that_never_asks_whether_pixels_touch_keeps_more_numbers_on_the_direct_page
    without = direct_page_variables(self.class.game(32, crowd: CROWD))
    with = direct_page_variables(self.class.game(32, crowd: CROWD, touching: true))

    assert_operator without - with, :>=, COLLIDE_SCRATCH_BYTES / 4,
                    "#{without} numbers on the direct page without the test, #{with} with it"
  end

  # The game that asks plays as the interpreter says.
  def test_the_crowded_game_asking_whether_pixels_touch_is_the_interpreters_on_every_pass
    game_player.run(self.class.game(32, crowd: CROWD, touching: true).program(console: :snes), frames: 10)
  end

  private def direct_page_variables(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rom.built.variables.values.count { |at| VBlank::IR::Backends::SNES::Memory.direct?(at) }
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
  # not; on the direct page, 544; with `b`, which stays in a byte, kept in two bytes
  # (SNES::HalfVariables), 495.
  def test_a_turn_working_three_numbers_costs_under_520_master_clocks
    cost = clocks_a_turn(0)
    assert_operator cost, :<, 520, "a turn costs #{cost.round(1)} master clocks"
  end

  def test_a_turn_in_a_crowded_game_costs_under_520_master_clocks
    cost = clocks_a_turn(CROWD)
    assert_operator cost, :<, 520, "a turn costs #{cost.round(1)} master clocks"
  end

  # The numbers are the interpreter's on every pass, the crowded game's too.
  def test_the_crowded_game_is_the_interpreters_on_every_pass
    game_player.run(self.class.game(32, crowd: CROWD).program(console: :snes), frames: 10)
  end
end
