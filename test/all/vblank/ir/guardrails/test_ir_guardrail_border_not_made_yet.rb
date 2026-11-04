# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a build that shows the game's screen in a border does not make yet is refused by name
# (Guardrails::Checks::BorderNotMadeYet), and the same game builds for the Color as before.
class TestIrGuardrailBorderNotMadeYet < Minitest::Test
  Check = VBlank::IR::Guardrails::Checks::BorderNotMadeYet

  private def game(&block) = VBlank.game("BORDERED", consoles: %i[gbc gba], variants: { gba: :color_screen }, &block)

  private def findings(made, console: :gba) = Check.new.detect(made.program(console: console))

  private def with_bar
    game do
      screen :tiled
      image :dark, "#" => :blue do "########\n" * 8 end
      tiles :bar_tiles, "#" => :dark
      status_bar :hud, tiles: :bar_tiles, map: Array.new(32) { "#" * 32 }, top: 128
      game_loop { wait_vblank }
    end
  end

  private def hiding_sprites
    game do
      screen :tiled
      image :dot, "#" => :white do "########\n" * 8 end
      sprite :dot, at: [8, 8]
      game_loop { hide_sprites if pressed(:a) }
    end
  end

  def test_a_status_bar_is_refused_in_a_border
    found = findings(with_bar)

    assert_equal [:border_not_made_yet], found.map(&:check).uniq
    assert_match(/status bar/, found.first.message)
    assert_match(/in a border/, found.first.message)
    assert_equal :error, found.first.severity
  end

  def test_hide_sprites_is_refused_in_a_border
    assert_match(/hide_sprites/, findings(hiding_sprites).first.message)
  end

  def test_the_color_build_of_the_same_game_is_not_refused
    assert_empty findings(with_bar, console: :gbc)
    assert_empty findings(hiding_sprites, console: :gbc)
  end

  def test_a_game_that_uses_none_of_them_is_not_refused
    made = game do
      screen :tiled
      image :dot, "#" => :white do "########\n" * 8 end
      sprite :dot, at: [8, 8]
      fade :black, 50
      game_loop { wait_vblank }
    end

    assert_empty findings(made)
  end
end
