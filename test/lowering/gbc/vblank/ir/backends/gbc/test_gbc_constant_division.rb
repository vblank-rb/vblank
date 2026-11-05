# frozen_string_literal: true

require "test_helper"
require "stringio"

# Dividing by a number written in the game on the Game Boy Color: a power of two of either sign is a
# shift or an AND where the sum is, and a byte is a long division whose remainder fits a register,
# rather than the runtime's divide of any two numbers. The answers, for every numerator, are
# test/all/vblank/ir/test_constant_divisor.rb's; this is the time, read from where the emulator says
# it went.
class TestGBCConstantDivision < Minitest::Test
  DIVIDE_ROUTINES = /\Art_(u?div|mod)/

  # A score pulled apart into digits, as drawing a number does: each pass a divide and a remainder,
  # by ten or by a power of two, twenty times.
  private def digits(divisor)
    VBlank.game("DIGITS", consoles: %i[gbc]) do
      total = var :total, 0
      n = var :n, 0
      d = var :d, 10
      game_loop do
        n += 7919
        repeat(20) do |i|
          total += case divisor
                   when :worked_out then ((n + i) / d) % d
                   when :power_of_two then ((n + i) / -16) % -16
                   else ((n + i) / 10) % 10
                   end
        end
      end
    end
  end

  private def divide_share(game)
    rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, settle: 20, frames: 6) # settle counts frames here: past the power-on clearing
    result.runtime.select { |spent| spent.routine.to_s.match?(DIVIDE_ROUTINES) }.sum(&:share)
  end

  def test_a_written_power_of_two_never_reaches_a_divide_routine
    assert_equal 0, divide_share(digits(:power_of_two))
  end

  # A remainder that fits a register, and a divisor in one, against the routine's four bytes of each:
  # a quarter of the time or less.
  def test_a_written_byte_divides_in_a_fraction_of_the_time
    assert_operator divide_share(digits(:written)), :<, divide_share(digits(:worked_out)) / 4
  end
end
