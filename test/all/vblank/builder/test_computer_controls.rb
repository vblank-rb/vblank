# frozen_string_literal: true

require "test_helper"

# A GAME'S OWN KEYS ON A COMPUTER: what `computer_keys` and `computer_gamepad` refuse. What each
# window does with the keys is tested with that window (test_native_window.rb, test_settings.rb,
# test_js_page_menu.rb), and that a cartridge is built as without them in
# test/lowering/gba/vblank/builder/test_computer_controls_cartridge.rb.
class TestComputerControls < Minitest::Test
  private def built_with(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder
  end

  private def refusal(&block) = assert_raises(ArgumentError) { built_with(&block) }.message

  def test_keys_and_gamepad_buttons_no_button_has_are_taken
    assert built_with {
      computer_keys a: :d, left: %i[space]
      computer_gamepad a: :west
      game_loop {}
    }
  end

  # The pinball case: the right arrow cannot press A, since it presses Right, which the game's
  # menus need.
  def test_a_key_the_layout_gives_another_button_is_refused_saying_why
    said = refusal { computer_keys a: :right }

    assert_match(/already presses :right on a computer/, said)
    assert_match(/A key presses one button/, said)
  end

  def test_a_key_the_window_keeps_is_refused
    assert_match(/keeps for itself \(Pause\)/, refusal { computer_keys a: :p })
    assert_match(/keeps for itself/, refusal { computer_keys a: :tab })
  end

  def test_one_key_for_two_buttons_is_refused
    assert_match(/gives :d to :a and :b/, refusal { computer_keys a: :d, b: :d })
  end

  def test_a_button_has_room_for_two_keys
    assert_match(/room for 2 keys/, refusal { computer_keys a: %i[d g] })
    assert_match(/give them to another button/, refusal { computer_keys select: :q })
  end

  def test_an_unknown_key_or_button_is_refused
    assert_match(/names no key VBlank knows/, refusal { computer_keys a: :f13 })
    assert_match(/names no button a computer's window has/, refusal { computer_keys x: :d })
  end

  def test_a_gamepad_button_the_layout_uses_is_refused
    said = refusal { computer_gamepad a: :south }

    assert_match(/already uses/, said)
    assert_match(/:west :north :left_stick :right_stick/, said)
  end

  # A game for two or more players has player 2 on the keyboard's right hand (I J K L, O, U and
  # the digits 7 to 0), so none of those can be one of player 1's added keys. A game for one
  # player has no player 2, and is free to take them.
  def test_a_game_for_more_players_keeps_player_twos_keys
    said = assert_raises(ArgumentError) { built_for_players(2) { computer_keys a: :o } }.message

    assert_match(/presses player 2's :a on a computer/, said)
    assert built_for_players(2) { computer_keys a: :d }
    assert built_for_players(1) { computer_keys a: :o, l: 7 }
    assert built_with { computer_keys a: :o }
  end

  private def built_for_players(most, &block)
    builder = Builder.new(options: VBlank::Cartridge::Options.new(players: most))
    builder.instance_eval(&block)
    builder
  end

  def test_keys_are_named_in_one_line
    said = refusal do
      computer_keys a: :d
      computer_keys b: :q
    end

    assert_match(/already names its `computer_keys`/, said)
  end
end
