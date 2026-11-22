# frozen_string_literal: true

require "test_helper"

# The list of numbers each runtime is handed for the keys and gamepad buttons a game adds
# (IR::ComputerControls.runtime_numbers), which rg_window.c, Live::Settings and rg_page.js read.
class TestIRComputerControls < Minitest::Test
  def test_the_runtimes_read_a_count_then_a_button_a_kind_and_a_number_each
    numbers = VBlank::IR::ComputerControls.runtime_numbers([%i[a key d], %i[a pad west]])

    assert_equal [2, 0, 0, 7, 0, 1, 2], numbers
  end

  # Player 2 has a key for every button a window has keys for, X, Y and C among them, and none is
  # player 1's or the window's own.
  def test_player_twos_keys_are_every_button_and_nobody_elses
    controls = VBlank::IR::ComputerControls
    keys = controls::SECOND_PLAYER_KEYS

    assert_equal controls::BUTTONS.sort, keys.values.sort
    assert_empty keys.keys & controls::LAYOUT_KEYS.values.flatten
    assert_empty keys.keys & controls::WINDOW_KEYS.keys
    assert_empty keys.keys & %i[f1 f3 f5 f9 f11]
  end

  def test_a_game_for_the_playstation_can_add_a_key_for_l2
    entries = VBlank::IR::ComputerControls.keys_entries!({ l2: :d }, console: VBlank::Console::PLAYSTATION)

    assert_equal [%i[l2 key d]], entries
  end

  # E is L2's own key on a PlayStation, and so cannot be added to another button there; on the
  # Advance, which has no L2, nobody has it.
  def test_l2s_key_is_taken_only_on_a_console_with_l2
    controls = VBlank::IR::ComputerControls
    error = assert_raises(ArgumentError) { controls.keys_entries!({ a: :e }, console: VBlank::Console::PLAYSTATION) }

    assert_match(/already presses :l2/, error.message)
    assert_equal [%i[a key e]], controls.keys_entries!({ a: :e }, console: VBlank::Console.described(:gba))
  end

  def test_a_game_that_adds_none_hands_over_a_count_of_nought
    assert_equal [0], VBlank::IR::ComputerControls.runtime_numbers(nil)
  end
end
