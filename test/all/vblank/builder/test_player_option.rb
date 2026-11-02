# frozen_string_literal: true

require "test_helper"

# `player:` on the button verbs, as far as every console agrees: which number means what, and what
# a console with one controller says. What two controllers do is
# test/console/snes/vblank/builder/test_two_players.rb.
class TestPlayerOption < Minitest::Test
  private def built_for(console, err: StringIO.new, &game)
    VBlank.build("PLAYERS", console: console, out: StringIO.new, err: err, &game)
  end

  def test_a_console_with_one_controller_refuses_the_second_player_in_plain_words
    %i[gba gbc genesis].each do |console|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) do
        built_for(console, err: said) { game_loop { halt if held(:left, player: 2) } }
      end

      assert_match(/second controller/, said.string)
    end
  end

  def test_any_player_on_a_console_with_one_controller_is_that_controller
    built_for(:gba) { game_loop { halt if pressed(:start, player: :any) } }
  end

  def test_a_player_that_does_not_exist_is_refused_in_plain_words
    error = assert_raises(ArgumentError) do
      built_for(:snes) { game_loop { halt if held(:left, player: 3) } }
    end

    assert_match(/not a player/, error.message)
  end

  def test_a_second_players_name_is_not_a_button_a_game_can_ask_about
    assert_raises(ArgumentError) do
      built_for(:snes) { game_loop { halt if held(:p2_left) } }
    end
  end
end
