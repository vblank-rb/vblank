# frozen_string_literal: true

require "test_helper"

# The list of numbers each runtime is handed for the keys and gamepad buttons a game adds
# (IR::ComputerControls.runtime_numbers), which rg_window.c, Live::Settings and rg_page.js read.
class TestIRComputerControls < Minitest::Test
  def test_the_runtimes_read_a_count_then_a_button_a_kind_and_a_number_each
    numbers = VBlank::IR::ComputerControls.runtime_numbers([%i[a key d], %i[a pad west]])

    assert_equal [2, 0, 0, 7, 0, 1, 2], numbers
  end

  # Player 2 has a key for every button, X, Y and C among them, and none is player 1's or the
  # window's own.
  def test_player_twos_keys_are_every_button_and_nobody_elses
    controls = VBlank::IR::ComputerControls
    keys = controls::SECOND_PLAYER_KEYS

    assert_equal VBlank::IR::Buttons::NAMES.sort, keys.values.sort
    assert_empty keys.keys & controls::LAYOUT_KEYS.values.flatten
    assert_empty keys.keys & controls::WINDOW_KEYS.keys
    assert_empty keys.keys & %i[f1 f3 f5 f9 f11]
  end

  def test_a_game_that_adds_none_hands_over_a_count_of_nought
    assert_equal [0], VBlank::IR::ComputerControls.runtime_numbers(nil)
  end
end
