# frozen_string_literal: true

require "test_helper"
require "stringio"

# A DIVISION COSTS WHAT ITS NUMBERS NEED. The answers are test_snes_int32's and test_dsl_expression's;
# these are about the time, read off the running cartridge.
class TestSNESDivisionCost < Minitest::Test
  # Divides a variable, so nothing can be worked out while building, by a divisor written in the game,
  # or by +ten+, a variable holding 10, so that the runtime's divide is the one that answers (a number
  # under 65536 divided by a written byte is the console's divider in place: test_snes_constant_division).
  private def dividing_game(name, repeats:, &sum)
    VBlank.game(name, consoles: %i[snes]) do
      number = var :number, 1000
      ten = var :ten, 10
      total = var :total, 0
      game_loop do
        number += 7
        repeat(repeats) { total += sum.call(number, ten) }
      end
    end
  end

  private def profile(game) = rom_of(game).profile(out: StringIO.new, settle: 10, frames: 20)
  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
  private def routines_of(result) = result.runtime.map { |spent| spent.routine.to_s }

  def test_a_small_number_divided_by_a_byte_walks_no_bits
    routines = routines_of(profile(dividing_game("BY A BYTE", repeats: 20) { |number, ten| number / ten }))

    assert_includes routines, "rt_div32"
    refute_includes routines, "rt_udiv32_bit"
  end

  def test_a_large_number_divided_by_a_byte_walks_no_bits
    routines = routines_of(profile(dividing_game("LARGE BY BYTE", repeats: 20) { |number| (number * 70_000) % 10 }))

    refute_includes routines, "rt_udiv32_bit"
  end

  def test_a_written_power_of_two_calls_no_division
    routines = routines_of(profile(dividing_game("BY FOUR", repeats: 20) { |number| number / 4 }))

    refute_includes routines, "rt_div32"
  end

  # Thirty divisions of a small number by one over a byte. At thirty-two steps each they run past a
  # frame.
  def test_a_small_number_skips_the_steps_that_can_only_give_nought
    result = profile(dividing_game("BY WIDE", repeats: 30) { |number| number / 1000 })

    assert_equal({ 1 => 20 }, result.passes_by_frames)
  end

  def test_a_game_that_does_not_divide_carries_no_division
    game = VBlank.game("NO DIVIDING", consoles: %i[snes]) do
      total = 0
      game_loop { total += 3 }
    end

    refute_includes rom_of(game).built.code.keys, "rt_udiv32"
  end
end
