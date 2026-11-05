# frozen_string_literal: true

require "test_helper"
require "stringio"
require "constant_division_games"

# Dividing by a number written in the game on the Super Nintendo: a number under 65536 by a byte goes
# straight to the console's divider where the sum is, and a power of two of either sign is a shift or
# an AND, never a call of the runtime's divide. The answers, for every numerator, are
# test/all/vblank/ir/test_constant_divisor.rb's; this is that the shortcut is taken, read from where
# bsnes says the time went.
class TestSNESConstantDivision < Minitest::Test
  include ConstantDivisionGames

  DIVIDE_ROUTINES = /\Art_(div|mod|udiv)32/

  # +settle+ passes first: without +small+, ten take the numbers past 65536.
  private def profile(divisor, small: true, settle: 2)
    game = digits_game(:snes, divisor, repeats: 100, small: small)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: settle, frames: 4)
  end

  def test_a_number_under_65536_by_a_written_byte_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(:written), DIVIDE_ROUTINES)
  end

  def test_a_written_negative_power_of_two_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(:power_of_two, small: false), DIVIDE_ROUTINES)
  end

  # ...where a divisor the game works out does, so the profile would have shown it; and the pass of
  # it takes two frames where the written divisor's takes one.
  def test_a_worked_out_divisor_still_divides
    worked_out = profile(:worked_out)

    assert_operator divide_share(worked_out, DIVIDE_ROUTINES), :>, 0
    assert_operator worked_out.fps, :<, profile(:written).fps
  end

  # A number with a top half by a written byte is the runtime's, which divides it.
  def test_a_wide_number_by_a_written_byte_reaches_the_divide_routine
    assert_operator divide_share(profile(:written, small: false, settle: 10), DIVIDE_ROUTINES), :>, 0
  end
end
