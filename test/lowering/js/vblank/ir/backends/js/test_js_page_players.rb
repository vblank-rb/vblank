# frozen_string_literal: true

require "test_helper"
require "web_page"

# MORE THAN ONE PLAYER ON A WEB PAGE: the keyboard is player 1 and its right hand player 2 (I J K
# L, O, U, 7 to 0), and each controller is the player it took when it was connected, the lowest
# no controller has. The desktop window and vblank run keep the same rule (test_native_seats.rb,
# test_seats.rb). Each picture is held to the interpreter's with the same players' buttons held.
class TestJSPagePlayers < Minitest::Test
  include WebPage

  # A row of squares for each of four players, one for each button held, so one picture says who
  # holds what.
  private def players_game
    buttons = advance_buttons
    VBlank.game "PLAYERS", consoles: %i[gba], players: { computer: 1..4, else: 1 } do
      screen :bitmap
      game_loop do
        clear_screen :black
        (1..4).each do |player|
          buttons.each_with_index do |button, i|
            fill_rect i * 10, player * 10, 8, 8, :white if held(button, player: player)
          end
        end
      end
    end
  end

  # The picture the page shows after +steps+ and two frames, against the interpreter's with
  # +held+ (names such as :p2_right) held from the second frame.
  private def assert_page_holds(steps, held, moment, game: players_game)
    picture = pictures_in(played_page([*steps, "play 2", "picture"], game)).first
    interpreter = Reference.new.input_each_frame { |frame| frame >= 2 ? held : [] }
                           .run(game.checked_program(err: nil, console: :gba), frames: 2)

    assert_same_picture interpreter.screen.shown, picture, moment
  end

  # The key words under the game name player 2's only for a game more than one person plays.
  def test_the_page_names_player_twos_keys_for_a_game_of_more_players
    assert_match(%r{Player 2: <kbd>I</kbd>}, built_page(players_game))
    refute_match(%r{Player 2: <kbd>}, built_page)
  end

  # Each of player 2's keys (IR::ComputerControls::SECOND_PLAYER_KEYS, by the browser's name for
  # it) holds its button, and the arrows stay player 1's.
  def test_the_keyboards_right_hand_is_player_two
    keys = VBlank::IR::ComputerControls::SECOND_PLAYER_KEYS
    codes = keys.keys.map { |name| name.is_a?(Integer) ? "Digit#{name}" : "Key#{name.upcase}" }
    held = keys.values.map { |button| :"p2_#{button}" }

    assert_page_holds([*codes.map { |code| "down #{code}" }, "down ArrowLeft"], held + %i[left],
                      "with every one of player 2's keys held, and the left arrow")
  end

  # A game that names no players plays as before: every controller is player 1's, and player 2's
  # keys are nobody's.
  def test_a_game_for_one_player_has_every_controller_as_player_one
    steps = ["pad 0 connect", "pad 1 connect", "pad 1 press 15", "down KeyL"]

    assert_page_holds(steps, %i[right], "with the second controller's right held and L", game: buttons_game)
  end

  def test_controllers_are_players_in_the_order_they_are_connected
    steps = ["pad 2 connect", "pad 0 connect", "pad 1 connect", "pad 2 press 15", "pad 0 press 14", "pad 1 press 12"]

    assert_page_holds(steps, %i[right p2_left p3_up], "with three controllers connected one after another")
  end

  # Taken out, a controller's player is free, and the next one connected takes it; the others keep theirs.
  def test_a_controller_connected_again_takes_the_lowest_free_player
    steps = ["pad 0 connect", "pad 1 connect", "pad 2 connect", "pad 1 disconnect", "pad 3 connect",
             "pad 2 press 15", "pad 3 press 14"]

    assert_page_holds(steps, %i[p3_right p2_left], "with the second controller taken out and a fourth connected")
  end
end
