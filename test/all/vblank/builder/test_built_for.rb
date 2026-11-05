# frozen_string_literal: true

require "test_helper"

# ONE GAME FILE, A CHOICE FOR EACH CONSOLE. A game for several consoles asks `built_for?` as its
# block runs, and each console's build gets the picture the game chose for it: on every run, the
# game built for that run's console, checked against the interpreter.
class TestBuiltFor < Minitest::Test
  FIVE = %i[gba gbc snes genesis ps1].freeze
  COLOR_FOR = { gba: :red, gbc: :green, snes: :blue, genesis: :white, ps1: :yellow }.freeze

  private def game
    VBlank.game "WHICH", consoles: FIVE do
      screen :bitmap
      clear_screen(COLOR_FOR.find { |console, _| built_for?(console) }.last)
      halt
    end
  end

  def test_each_console_build_shows_what_the_game_chose_for_it
    screen = game_player.run(game.program(console: game_console)).screen
    assert_equal shown(COLOR_FOR.fetch(game_console)), screen.pixel(10, 10)
  end

  def test_a_build_for_a_computer_answers_for_the_console_it_plays_as
    program = game.checked_program(console: game_console, err: nil, for_computer: true)
    assert_equal shown(COLOR_FOR.fetch(game_console)), game_player.run(program).screen.pixel(10, 10)
  end

  def test_a_console_the_game_does_not_name_is_refused
    asks = VBlank.game("ASKS", consoles: %i[gba gbc]) do
      screen :bitmap
      clear_screen(built_for?(:snes) ? :blue : :red)
      halt
    end
    error = assert_raises(ArgumentError) { asks.program(console: :gba) }
    assert_match(/not one of the consoles/i, error.message)
    assert_match(/consoles: %i\[gba gbc snes\]/, error.message)
  end

  def test_a_console_there_is_none_of_is_refused
    asks = VBlank.game("ASKS", consoles: %i[gba]) do
      var :far, built_for?(:n64) ? 1 : 0
      halt
    end
    error = assert_raises(ArgumentError) { asks.program(console: :gba) }
    assert_match(/no console named :n64/, error.message)
  end

  def test_a_variant_the_console_does_not_have_is_refused
    asks = VBlank.game("ASKS", consoles: %i[gba snes]) do
      var :chip, built_for?(:snes, variant: :turbo) ? 1 : 0
      halt
    end
    error = assert_raises(ArgumentError) { asks.program(console: :gba) }
    assert_match(/no variant named :turbo/, error.message)
  end
end
