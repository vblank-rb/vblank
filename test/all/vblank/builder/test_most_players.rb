# frozen_string_literal: true

require "test_helper"

# THE MOST PLAYERS A BUILD SEATS, asked while the game is built (`most_players`), so a game says
# how many players it takes once, in `players:`, and lays out its seats from the answer.
class TestMostPlayers < Minitest::Test
  private def game(players: { computer: 1..4, else: 1 })
    VBlank.game "SEATS", consoles: %i[gba], players: players do
      var :seats, most_players
      game_loop {}
    end
  end

  private def seats_in(program) = Reference.new.run(program, frames: 2)[:seats]

  def test_a_cartridge_seats_what_the_else_key_says
    assert_equal 1, seats_in(game.build_rom(profile: false, out: nil, err: nil).source_program)
  end

  def test_a_computer_build_seats_what_the_computer_key_says
    assert_equal 4, seats_in(game.checked_program(err: nil))
  end

  def test_a_game_for_one_number_seats_that_number_everywhere
    assert_equal 1, seats_in(game(players: 1).build_rom(profile: false, out: nil, err: nil).source_program)
    assert_equal 1, seats_in(game(players: 1).checked_program(err: nil))
  end

  def test_a_range_seats_the_top_of_it
    assert_equal 3, seats_in(game(players: 2..3).checked_program(err: nil))
  end

  def test_a_game_that_does_not_say_its_players_is_told_to
    error = assert_raises(ArgumentError) { game(players: nil).checked_program(err: nil) }

    assert_match(/most_players/, error.message)
    assert_match(/players:/, error.message)
  end

  # A game built for a web page or as C is told the same, since both are builds for a computer.
  def test_a_web_page_and_a_desktop_program_seat_the_same_number
    assert_equal 4, seats_in(VBlank::IR::Backends::JS.new.checked_program(game, err: nil))
    assert_equal 4, seats_in(VBlank::IR::Backends::Native.new.checked_program(game, err: nil))
  end
end
