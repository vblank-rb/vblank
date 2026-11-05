# frozen_string_literal: true

require "test_helper"
require "stringio"
require "constant_division_games"

# Dividing by a number written in the game on the Genesis: the 68000's own DIVU, or a shift for a
# power of two, written where the sum is, never the runtime's divide, which walks the numerator a
# bit at a time, 32 times. The answers are test/all/vblank/ir/test_constant_divisor.rb's; this is
# that the shortcut is taken, read from where Genesis Plus GX says the time went.
class TestGenesisConstantDivision < Minitest::Test
  include ConstantDivisionGames

  DIVIDE_ROUTINES = /\Art_(div|mod|unsigned_divide)/

  private def profile(divisor)
    rom = digits_game(:genesis, divisor, repeats: 100).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new,
                                                                  profile: false)
    rom.profile(out: StringIO.new, settle: 2, frames: 4)
  end

  def test_a_written_divisor_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(:written), DIVIDE_ROUTINES)
  end

  def test_a_written_power_of_two_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(:power_of_two), DIVIDE_ROUTINES)
  end

  # ...where a divisor the game works out does, so the profile would have shown it.
  def test_a_worked_out_divisor_still_divides
    assert_operator divide_share(profile(:worked_out), DIVIDE_ROUTINES), :>, 0
  end

  # Two hundred divides a pass by the routine take three frames; by DIVU they fit in one.
  def test_the_written_divisor_plays_a_pass_a_frame
    assert_operator profile(:written).fps, :>, 59
  end
end
