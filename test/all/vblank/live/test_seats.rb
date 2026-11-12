# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# WHICH PLAYER EACH GAMEPAD AND KEY IS in `vblank run`'s window (Live::Seats): the same rule as the
# desktop window's (test_native_seats.rb) and the web page's (test_js_page_players.rb).
class TestSeats < Minitest::Test
  Seats = VBlank::Live::Seats
  KEYS = VBlank::IR::ComputerControls::KEYS

  def test_gamepads_are_players_in_the_order_they_are_plugged_in
    seats = Seats.new

    assert_equal [1, 2, 3], [40, 41, 42].map { |id| seats.join(id) }
    assert_equal 1, seats.player_of(40)
  end

  def test_a_gamepad_plugged_in_again_takes_the_lowest_free_player
    seats = Seats.new
    [40, 41, 42].each { |id| seats.join(id) }
    seats.leave(41)

    assert_nil seats.player_of(41)
    assert_equal 3, seats.player_of(42)
    assert_equal [2, 4], [43, 41].map { |id| seats.join(id) }
  end

  def test_a_gamepad_reported_twice_keeps_its_player
    seats = Seats.new

    assert_equal [1, 1, 2], [40, 40, 41].map { |id| seats.join(id) }
  end

  # Each of player 2's keys holds its button, by the names a game's run reads them by.
  def test_the_keyboards_right_hand_is_player_two
    VBlank::IR::ComputerControls::SECOND_PLAYER_KEYS.each do |name, button|
      held = Seats.second_player_buttons(down: ->(code) { code == KEYS.fetch(name) }, free: ->(_) { true })

      assert_equal [:"p2_#{button}"], held, "#{name.inspect} is player 2's #{button}"
    end
  end

  # A key player 1 or a hotkey has (a player chose O for A in the settings file) is not player 2's.
  def test_a_key_somebody_else_has_is_not_player_twos
    down = [KEYS.fetch(:l), KEYS.fetch(:o)]
    held = Seats.second_player_buttons(down: ->(code) { down.include?(code) }, free: ->(code) { code != KEYS.fetch(:o) })

    assert_equal %i[p2_right], held
  end

  def test_a_gamepads_buttons_are_its_players
    assert_equal %i[a left], Seats.buttons_as_player(%i[a left], 1)
    assert_equal %i[p3_a p3_left], Seats.buttons_as_player(%i[a left], 3)
  end

  # Only a game that seats two or more is played this way: one naming one player, or none, plays as
  # it always did.
  def test_only_a_game_for_several_players_seats_them_apart
    assert_equal [false, false, false, true], [nil, 0, 1, 2].map { |most| Seats.several_players?(most) }
  end
end
