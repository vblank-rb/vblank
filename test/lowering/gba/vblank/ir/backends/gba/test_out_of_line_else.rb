# frozen_string_literal: true

require "test_helper"

# An else that only stops the game is written after its routine's return (FaultStops#later), so
# the test before it costs one branch not taken. Only an else that stops on every path can go
# there: nothing jumps from it back to the end of the test, so an else that can finish runs on
# into whatever was written after the routine. In a routine kept in the quick memory that is its
# table of numbers, read as instructions.
#
# An `elsif` with nothing in it is the shape that showed it: the else holds one test with no
# body, which stops on no path at all.
class TestOutOfLineElse < Minitest::Test
  def test_an_empty_elsif_in_a_routine_goes_on_to_the_end_of_the_test
    assert_same_totals do
      a = var :a, 0
      b = var :b, 0
      total = var :total, 0
      n = var :n, 0
      func :step do
        if a > 100
          total += 1
        elsif b == 0
        end
        total += 5
      end
      game_loop do
        call :step
        b ^= 1
        n += 1
        halt if n == 12
      end
    end
  end

  def test_an_empty_elsif_in_the_game_loop_goes_on_to_the_end_of_the_test
    assert_same_totals do
      a = var :a, 0
      b = var :b, 0
      total = var :total, 0
      n = var :n, 0
      game_loop do
        if a > 100
          total += 1
        elsif b == 0
        end
        total += 5
        b ^= 1
        n += 1
        halt if n == 12
      end
    end
  end

  private def assert_same_totals(&game)
    rom = VBlank.build("ELSE", console: :gba, out: StringIO.new, err: StringIO.new, &game)
    played = Reference.new.run(rom.source_program, frames: 40)
    cartridge = VBlank::Diagnostics::Verifier.new(rom, frames: 40, vars: rom.var_addresses)

    assert_equal 60, played[:total]
    assert_equal played[:total], cartridge.var(:total)
  end
end
