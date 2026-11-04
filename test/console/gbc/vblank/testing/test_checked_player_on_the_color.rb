# frozen_string_literal: true

require "test_helper"

# A GAME THE COLOR'S BUILD REFUSES IS NOT PLAYED AS ONE: every run that plays games as the Color
# (its cartridge's, and the game as C, JavaScript and Ruby built as it) checks the program as that
# build does before playing it (Testing::BuildChecks), and refuses it in the build's words.
class TestCheckedPlayerOnTheColor < Minitest::Test
  private def blocky_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :dot, width: 8, height: 8, data: Array.new(64, :white), colors: %i[black white]
      sprite :dot, at: [40, 40]
      game_loop { pixelate 8 }
    end
    b.finalize_program
    b.program
  end

  def test_a_game_showing_the_screen_in_blocks_is_refused_as_the_build_refuses_it
    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(blocky_game, frames: 2) }

    assert_match(/Game Boy Color cannot/, error.message)
    assert_match(/mosaic/, error.message)
  end
end
