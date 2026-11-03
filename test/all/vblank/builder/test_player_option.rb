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
    [0, 17, :third].each do |player|
      error = assert_raises(ArgumentError, player.inspect) do
        built_for(:snes) { game_loop { halt if held(:left, player: player) } }
      end

      assert_match(/not a player/, error.message)
    end
  end

  def test_a_console_refuses_a_player_past_its_controllers_in_plain_words
    { gba: /one controller/, gbc: /one controller/, snes: /controller 3/, genesis: /controller 3/ }.each do |console, words|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) do
        built_for(console, err: said) { game_loop { halt if pressed(:a, player: 3) } }
      end

      assert_match(words, said.string, console.to_s)
    end
  end

  def test_a_game_for_more_players_than_a_console_seats_is_refused_there
    { gba: 2, gbc: 2, snes: 3, genesis: 2 }.each do |console, players|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) do
        VBlank.build("PLAYERS", console: console, players: players, out: StringIO.new, err: said) { game_loop { halt } }
      end

      assert_match(/`players:`/, said.string, console.to_s)
    end
  end

  def test_a_game_for_one_player_builds_on_every_console
    %i[gba gbc snes genesis].each do |console|
      VBlank.build("PLAYERS", console: console, players: 1, out: StringIO.new, err: StringIO.new) { game_loop { halt } }
    end
  end

  def test_a_build_for_a_computer_takes_more_players_than_its_console_seats
    VBlank.build("PLAYERS", console: :gba, players: { gba: 1, computer: 1..8 }, cartridge: false, for_computer: true,
                            out: StringIO.new, err: StringIO.new) { game_loop { halt if held(:left, player: 8) } }
  end

  # A game for the Super Nintendo built for a computer is judged by what that build can do: the
  # computer's runtime counts the players connected, though the cartridge build does not yet, and
  # says so by name.
  def test_a_super_nintendo_game_built_for_a_computer_asks_how_many_players_are_connected
    counting = proc { game_loop { halt if players_connected > 1 } }
    VBlank.build("PLAYERS", console: :snes, cartridge: false, for_computer: true, out: StringIO.new,
                            err: StringIO.new, &counting)

    error = assert_raises(VBlank::BuildError) do
      VBlank.build("PLAYERS", console: :snes, out: StringIO.new, err: StringIO.new, &counting)
    end
    assert_match(/players_connected/, error.message)
  end

  def test_a_line_reading_a_player_past_the_ones_the_game_takes_is_refused_in_plain_words
    error = assert_raises(ArgumentError) do
      VBlank.build("PLAYERS", console: :snes, players: 1, out: StringIO.new, err: StringIO.new) do
        game_loop { halt if held(:left, player: 2) }
      end
    end

    assert_match(/players:/, error.message)
  end

  def test_players_that_are_not_a_number_of_players_are_refused_in_plain_words
    [0, 17, 3..2, 0..2, :two, { nes: 2 }].each do |players|
      error = assert_raises(ArgumentError, players.inspect) do
        VBlank.build("PLAYERS", console: :gba, players: players, out: StringIO.new, err: StringIO.new) { game_loop { halt } }
      end

      assert_match(/players:/, error.message, players.inspect)
    end
  end

  def test_a_second_players_name_is_not_a_button_a_game_can_ask_about
    assert_raises(ArgumentError) do
      built_for(:snes) { game_loop { halt if held(:p2_left) } }
    end
  end
end
