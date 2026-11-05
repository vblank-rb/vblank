# frozen_string_literal: true

require "test_helper"
require "stringio"
require "constant_division_games"

# Dividing by a number written in the game on the Game Boy Color: a power of two of either sign is a
# shift or an AND where the sum is, and a byte is a long division whose remainder fits a register,
# rather than the runtime's divide of any two numbers. The answers, for every numerator, are
# test/all/vblank/ir/test_constant_divisor.rb's; this is the time, read from where the emulator says
# it went.
class TestGBCConstantDivision < Minitest::Test
  include ConstantDivisionGames

  DIVIDE_ROUTINES = /\Art_(u?div|mod)/

  private def share_of(divisor)
    rom = digits_game(:gbc, divisor, repeats: 20).build_rom(console: :gbc, out: StringIO.new, err: StringIO.new,
                                                            profile: false)
    result = rom.profile(out: StringIO.new, settle: 20, frames: 6) # settle counts frames here: past the power-on clearing
    divide_share(result, DIVIDE_ROUTINES)
  end

  def test_a_written_power_of_two_never_reaches_a_divide_routine
    assert_equal 0, share_of(:power_of_two)
  end

  # A remainder that fits a register, and a divisor in one, against the routine's four bytes of each:
  # a quarter of the time or less.
  def test_a_written_byte_divides_in_a_fraction_of_the_time
    assert_operator share_of(:written), :<, share_of(:worked_out) / 4
  end
end
