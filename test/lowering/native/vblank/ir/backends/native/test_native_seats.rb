# frozen_string_literal: true

require "test_helper"

# WHICH PLAYER EACH GAMEPAD AND KEY IS in the desktop window (runtime/rg_seats.h): a gamepad takes
# the lowest player no gamepad has and keeps it while plugged in, and the keyboard's right hand is
# player 2. That the window hands them to the game is test_native_desktop.rb's.
class TestNativeSeats < Minitest::Test
  Zig = VBlank::IR::Backends::Native::Zig
  Computer = VBlank::IR::Backends::Computer
  ComputerControls = VBlank::IR::ComputerControls
  HARNESS = Ractor.make_shareable(File.expand_path("seats_harness.c", __dir__))

  def test_gamepads_are_players_in_the_order_they_are_plugged_in
    assert_equal [1, 2, 3, 1], asked("join 40", "join 41", "join 42", "player 40").flatten.map(&:to_i)
  end

  # Pulled out, a gamepad's player is free, and the next one plugged in takes the lowest free
  # player: the others keep theirs.
  def test_a_gamepad_plugged_in_again_takes_the_lowest_free_player
    answers = asked("join 40", "join 41", "join 42", "leave 41", "player 41", "player 42", "join 43", "join 41")

    assert_equal [1, 2, 3, 0, 3, 2, 4], answers.flatten.map(&:to_i)
  end

  def test_a_gamepad_reported_twice_keeps_its_player
    assert_equal [1, 1, 2], asked("join 40", "join 40", "join 41").flatten.map(&:to_i)
  end

  # The window's keys for player 2 are the layout IR::ComputerControls names, which is what a game's
  # own keys are refused against.
  def test_player_twos_keys_are_the_layout_the_build_keeps_free
    keys = ComputerControls::SECOND_PLAYER_KEYS
    numbers = keys.keys.map { |name| ComputerControls::KEYS.fetch(name) }
    answers = asked(*numbers.map { |number| "key #{number}" }, "key #{ComputerControls::KEYS.fetch(:x)}").flatten.map(&:to_i)

    assert_equal keys.values.map { |button| ComputerControls::BUTTONS.index(button) } + [-1], answers
  end

  # Only a game that seats two or more is played this way: one naming one player, or none, plays as
  # it always did, every gamepad and key player 1's.
  def test_only_a_game_for_several_players_seats_them_apart
    assert_equal [0, 0, 1, 1], asked("several 0", "several 1", "several 2", "several 4").flatten.map(&:to_i)
  end

  # The runtime is handed every player up to the last one holding a button, and at least player 1.
  def test_the_runtime_is_handed_players_up_to_the_last_holding_a_button
    assert_equal [1, 1, 2, 4], asked("count 0 0 0 0 .", "count 5 0 0 .", "count 0 1 0 .", "count 0 0 0 8 .").flatten.map(&:to_i)
  end

  # The harness's answers to +questions+, a line each, split into words.
  private def asked(*questions)
    exe = Zig.compile_without_sdl([HARNESS], mode: :checked)
    Computer::ProgramRun.run(exe, input: questions.map { |question| "#{question}\n" }.join).lines.map(&:split)
  end
end
