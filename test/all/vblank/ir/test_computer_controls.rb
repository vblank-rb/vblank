# frozen_string_literal: true

require "test_helper"

# The list of numbers each runtime is handed for the keys and gamepad buttons a game adds
# (IR::ComputerControls.runtime_numbers), which rg_window.c, Live::Settings and rg_page.js read.
class TestIRComputerControls < Minitest::Test
  def test_the_runtimes_read_a_count_then_a_button_a_kind_and_a_number_each
    numbers = VBlank::IR::ComputerControls.runtime_numbers([%i[a key d], %i[a pad west]])

    assert_equal [2, 0, 0, 7, 0, 1, 2], numbers
  end

  def test_a_game_that_adds_none_hands_over_a_count_of_nought
    assert_equal [0], VBlank::IR::ComputerControls.runtime_numbers(nil)
  end
end
