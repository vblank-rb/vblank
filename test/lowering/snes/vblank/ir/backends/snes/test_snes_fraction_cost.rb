# frozen_string_literal: true

require "test_helper"
require "stringio"

# What multiplying and dividing two numbers with a fraction costs on the Super Nintendo. The answers
# are test_snes_int32's.
class TestSNESFractionCost < Minitest::Test
  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  def test_a_game_with_no_fractions_carries_no_fraction_routines
    game = VBlank.game("WHOLE NUMBERS", consoles: %i[snes]) do
      total = var :total, 3
      game_loop { total *= total }
    end

    routines = rom_of(game).built.code.keys
    refute_includes routines, "rt_mul_fix"
    refute_includes routines, "rt_div_fix"
  end

  def test_a_game_with_fractions_carries_their_routines
    game = VBlank.game("FRACTIONS", consoles: %i[snes]) do
      n = var :n, 1.5
      total = var :total, 0.0
      game_loop { total = n * n }
    end

    assert_includes rom_of(game).built.code.keys, "rt_mul_fix"
  end
end
