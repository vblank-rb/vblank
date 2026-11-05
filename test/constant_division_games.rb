# frozen_string_literal: true

# The game each console's constant division cost test measures: a score pulled apart into digits,
# as drawing a number does, each pass a divide and a remainder +repeats+ times. The answers are
# test/all/vblank/ir/test_constant_divisor.rb's; these tests read where the time went.
module ConstantDivisionGames
  private

  # By ten (+divisor+ :written), by -16 (:power_of_two), or by a variable holding 10 (:worked_out),
  # which no lowering can know while building. With +small+ the numbers stay under 32768.
  def digits_game(console, divisor, repeats:, small: false)
    VBlank.game("DIGITS", consoles: [console]) do
      total = var :total, 0
      n = var :n, 0
      d = var :d, 10
      game_loop do
        if small
          n = (n + 7919) & 0x7FFF
        else
          n += 7919
        end
        repeat(repeats) do |i|
          total += case divisor
                   when :worked_out then ((n + i) / d) % d
                   when :power_of_two then ((n + i) / -16) % -16
                   else ((n + i) / 10) % 10
                   end
        end
      end
    end
  end

  # The share of +result+'s time (a console profiler's) spent in routines whose labels match +routines+.
  def divide_share(result, routines) = result.runtime.select { |spent| spent.routine.to_s.match?(routines) }.sum(&:share)
end
