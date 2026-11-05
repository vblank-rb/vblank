# frozen_string_literal: true

require "test_helper"
require "stringio"

# Dividing by a number written in the game on the PlayStation: a multiply (IR::ConstantDivisor) or a
# shift, never the runtime's divide, whose DIV waits dozens of cycles and is a call besides. The
# answers are test/all/vblank/ir/test_constant_divisor.rb's; this is that the shortcut is taken, read
# from where Beetle PSX says the time went.
class TestPS1ConstantDivision < Minitest::Test
  DIVIDE_ROUTINES = /\Art_(div|mod)32/

  # A score pulled apart into digits, as drawing a number does: each pass a divide by ten and a
  # remainder by ten, a few hundred times.
  private def digits(divisor)
    VBlank.game("DIGITS", consoles: %i[ps1]) do
      screen :bitmap, tear_free: true
      total = var :total, 0
      n = var :n, 0
      d = var :d, 10
      game_loop do
        n += 7919
        repeat(300) do |i|
          total += divisor == :worked_out ? ((n + i) / d) % d : ((n + i) / 10) % 10
        end
      end
    end
  end

  private def divide_share(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 4).runtime.select { |spent| spent.routine.to_s.match?(DIVIDE_ROUTINES) }.sum(&:share)
  end

  def test_a_written_divisor_never_reaches_the_divide_routine
    assert_equal 0, divide_share(digits(:written))
  end

  # ...where a divisor the game works out does, so the profile would have shown it.
  def test_a_worked_out_divisor_still_divides
    assert_operator divide_share(digits(:worked_out)), :>, 0
  end
end
