# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The keys a game adds (computer_keys) reach the window `vblank run` plays it in: the game built as
# Ruby carries them (LiveGame#controls), and the window's key table starts with them beside
# VBlank's own (Live::Settings, whose rules test_settings.rb holds).
class TestLiveGameControls < Minitest::Test
  # SDL's names for the keys asked about here.
  class KeyNames
    def name(key) = { 7 => "D", 27 => "X", 79 => "Right" }[key]
    def key(_name) = nil
  end

  private def game_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    VBlank::IR::Backends::Ruby.new.live_game(builder.program)
  end

  def test_the_window_starts_with_the_games_keys_beside_vblanks
    game = game_of do
      computer_keys a: :d
      computer_gamepad a: :west
      game_loop { wait_vblank }
    end
    settings = VBlank::Live::Settings.new(key_names: KeyNames.new, game_controls: game.controls)

    assert_equal "X, D / east, west", settings.button_text(0)
    assert_equal [79], settings.keys_of(:right), "the right arrow is still Right"
  end

  def test_a_game_that_adds_none_carries_none
    game = game_of { game_loop { wait_vblank } }

    assert_equal [0], game.controls.to_a
  end
end
