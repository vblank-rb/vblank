# frozen_string_literal: true

require "test_helper"
require "stringio"

# What dividing one number with a fraction by another costs on the PlayStation, read from where Beetle PSX
# says the time went. The answers are test_ps1_fractions.rb's; this is that the usual divides, the ones a
# 3D game makes for every corner it places, take the short ways through rt_div_fix. The R3000's own divide
# waits 36 cycles, and a numerator of 1.0 or more is past 32 bits once it is brought up by the fraction, so
# it takes two of them: that is the floor the bounds here sit above.
class TestPS1FractionDivideCost < Minitest::Test
  DIVIDE_ROUTINE = /\Art_div_fix/
  DIVIDES_A_PASS = 400
  CYCLES_A_FRAME = VBlank::Console::PLAYSTATION.cycles_a_frame

  # Each pass divides +numerator+ by +divisor+ DIVIDES_A_PASS times, both kept in variables so that
  # nothing is worked out when the game is built.
  private def dividing(numerator, divisor)
    divides = DIVIDES_A_PASS
    VBlank.game("DIVIDES", consoles: %i[ps1]) do
      screen :bitmap, tear_free: true
      n = var :n, numerator
      d = var :d, divisor
      total = var :total, 0.0
      game_loop do
        repeat(divides) { total = n / d }
      end
    end
  end

  # The processor's cycles one divide spent inside rt_div_fix, the call to it and the work around it left out.
  private def cycles_a_divide(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 4)

    assert_equal 1, result.slowest_frames, "every pass fits a frame, so a frame's time is one pass's divides"
    share = result.runtime.select { |spent| spent.routine.to_s.match?(DIVIDE_ROUTINE) }.sum(&:share)
    share * CYCLES_A_FRAME / DIVIDES_A_PASS
  end

  # 50.25 over 3.5, a distance over a depth: the numerator brought up is past 32 bits and the divisor past
  # sixteen, so one divide gives the answer's top digit and a second a guess at the bottom one, put right
  # with a multiply. The long division of two guessed digits, which this is not, took a third more.
  def test_a_usual_divide_by_one_or_more_costs_little_more_than_its_two_divides
    assert_operator cycles_a_divide(dividing(50.25, 3.5)), :<, 150
  end

  # 50.25 over 0.75: a divisor below 1.0 is one digit of sixteen bits, so each divide's answer is a digit
  # of the answer as it stands, with nothing to guess.
  def test_a_divide_by_less_than_one_costs_its_two_divides
    assert_operator cycles_a_divide(dividing(50.25, 0.75)), :<, 130
  end

  # 0.5 over 3.5: the numerator brought up still fits 32 bits, and one divide does it.
  def test_a_numerator_below_one_costs_one_divide
    assert_operator cycles_a_divide(dividing(0.5, 3.5)), :<, 75
  end
end
