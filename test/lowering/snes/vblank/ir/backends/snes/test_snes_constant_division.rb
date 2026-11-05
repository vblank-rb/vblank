# frozen_string_literal: true

require "test_helper"
require "stringio"

# Dividing by a number written in the game on the Super Nintendo: a number under 65536 by a byte goes
# straight to the console's divider where the sum is, and a power of two of either sign is a shift or
# an AND, never a call of the runtime's divide. The answers, for every numerator, are
# test/all/vblank/ir/test_constant_divisor.rb's; this is that the shortcut is taken, read from where
# bsnes says the time went.
class TestSNESConstantDivision < Minitest::Test
  DIVIDE_ROUTINES = /\Art_(div|mod|udiv)32/

  # A score under 65536 pulled apart into digits, as drawing a number does: each pass a divide and a
  # remainder, by ten or by a power of two, a hundred times.
  private def digits(divisor)
    VBlank.game("DIGITS", consoles: %i[snes]) do
      total = var :total, 0
      n = var :n, 0
      d = var :d, 10
      game_loop do
        n = (n + 7919) & 0x7FFF
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
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 2, frames: 4)
  end

  private def divide_share(result) = result.runtime.select { |spent| spent.routine.to_s.match?(DIVIDE_ROUTINES) }.sum(&:share)

  def test_a_written_byte_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(digits(:written)))
  end

  def test_a_written_negative_power_of_two_never_reaches_the_divide_routine
    assert_equal 0, divide_share(profile(digits(:power_of_two)))
  end

  # ...where a divisor the game works out does, so the profile would have shown it.
  def test_a_worked_out_divisor_still_divides
    assert_operator divide_share(profile(digits(:worked_out))), :>, 0
  end
end
