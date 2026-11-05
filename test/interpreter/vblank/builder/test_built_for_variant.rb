# frozen_string_literal: true

require "test_helper"

# `built_for?` asked about a console's variant, answered on the interpreter by name: no run plays a
# Super FX build of a game in test/all, so this is the interpreter's to answer.
class TestBuiltForVariant < Minitest::Test
  private def chip_game
    VBlank.game "CHIP", consoles: %i[gba snes] do
      var :chip, built_for?(:snes, variant: :superfx) ? 1 : 0
      var :plain, built_for?(:snes, variant: :none) ? 1 : 0
      game_loop {}
    end
  end

  def test_the_variant_is_asked_with_the_console
    chip = Reference.new.run(chip_game.program(console: :snes, variant: :superfx), frames: 1)
    plain = Reference.new.run(chip_game.program(console: :snes), frames: 1)
    advance = Reference.new.run(chip_game.program(console: :gba), frames: 1)
    assert_equal [1, 0], [chip[:chip], chip[:plain]]
    assert_equal [0, 1], [plain[:chip], plain[:plain]]
    assert_equal [0, 0], [advance[:chip], advance[:plain]]
  end
end
