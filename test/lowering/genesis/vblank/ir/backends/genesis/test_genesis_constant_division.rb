# frozen_string_literal: true

require "test_helper"
require "stringio"

# Dividing by a number written in the game on the Genesis: the 68000's own DIVU, or a shift for a
# power of two, written where the sum is, never the runtime's divide, which walks the numerator a
# bit at a time, 32 times. The answers are test/all/vblank/ir/test_constant_divisor.rb's; this is
# that the shortcut is taken, read from where Genesis Plus GX says the time went.
class TestGenesisConstantDivision < Minitest::Test
  DIVIDE_ROUTINES = /\Art_(div|mod|unsigned_divide)/

  # A score pulled apart into digits, as drawing a number does: each pass a divide and a remainder,
  # by ten or by a power of two, a hundred times.
  private def digits(divisor)
    VBlank.game("DIGITS", consoles: %i[genesis]) do
      total = var :total, 0
      n = var :n, 0
      d = var :d, 10
      game_loop do
        n += 7919
        repeat(100) do |i|
          total += case divisor
                   when :worked_out then ((n + i) / d) % d
                   when :power_of_two then ((n + i) / -16) % -16
                   else ((n + i) / 10) % 10
                   end
        end
      end
    end
  end

  private def profile(game)
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 2, frames: 4)
  end

  private def divide_share(result) = result.runtime.select { |spent| spent.routine.to_s.match?(DIVIDE_ROUTINES) }.sum(&:share)

  def test_a_written_divisor_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(digits(:written)))
  end

  def test_a_written_power_of_two_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(digits(:power_of_two)))
  end

  # ...where a divisor the game works out does, so the profile would have shown it.
  def test_a_worked_out_divisor_still_divides
    assert_operator divide_share(profile(digits(:worked_out))), :>, 0
  end

  # Two hundred divides a pass by the routine are over a frame; by DIVU they fit with room to spare.
  def test_the_written_divisor_plays_a_pass_a_frame
    assert_equal 59.9, profile(digits(:written)).fps.round(1)
  end
end
