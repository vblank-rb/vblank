# frozen_string_literal: true

# HOW MANY PLAYERS ARE CONNECTED, on a console with one controller: always the one. Played by
# each console whose build reads one controller (test/console/gba/vblank/builder/test_players_connected.rb,
# test/console/gbc/vblank/builder/test_players_connected_on_the_color.rb,
# test/console/genesis/vblank/builder/test_players_connected_on_the_genesis.rb). How the count grows with
# more players is test/many_players_tests.rb.
module PlayersConnectedTests
  private def counting_players
    b = VBlank::Builder.new
    b.instance_eval do
      connected = 0
      game_loop do
        connected = players_connected
        clear_screen :black
        draw_rect_at connected * 8, 8, 4, 4, :red
      end
    end
    b.finalize_program
    b.program
  end

  def test_one_player_is_connected_on_a_console_with_one_controller
    run = game_player.hold(:right).run(counting_players, frames: 4)

    assert_equal 1, run[:connected]
    assert_equal VBlank::Testing.shown(:red), run.screen.pixel(9, 9), "the marker one step along"
  end

  def test_one_player_is_connected_with_no_button_held
    assert_equal 1, game_player.run(counting_players, frames: 3)[:connected]
  end
end
