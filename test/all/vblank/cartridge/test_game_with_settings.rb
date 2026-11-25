# frozen_string_literal: true

require "test_helper"

# A game told its settings on the handle: `game.with_settings(room: 2)` is the same game built as
# `settings: { room: 2 }` builds it, held as one value with its features and starts, so a test hands
# one handle to everything that builds a game and never a hash beside it.
class TestGameWithSettings < Minitest::Test
  # A room whose number and whose hero's place are settings, the hero walking a pixel a pass.
  module Room
    def self.game
      VBlank.game("ROOM", consoles: %i[gba gbc snes genesis ps1 dos]) do
        screen :bitmap
        room = var :room, setting(:room, 1)
        hero_x = var :hero_x, setting(:hero_x, 10)
        game_loop do
          hero_x += 1
          room += 0
        end
      end
    end
  end

  private def played(game, frames) = game_player.run(game.program(console: game_console), frames: frames)

  def test_a_game_with_settings_reads_them_as_settings_given_on_a_call
    player = played(Room.game.with_settings(room: 3, hero_x: 50), 2)

    assert_equal 3, player[:room]
    assert_equal 52, player[:hero_x]
  end

  def test_later_settings_go_over_earlier_ones
    player = played(Room.game.with_settings(room: 3, hero_x: 50).with_settings(hero_x: 70), 1)

    assert_equal 3, player[:room]
    assert_equal 71, player[:hero_x]
  end

  def test_settings_go_with_features_and_starts
    player = played(Room.game.with_settings(room: 4).starting_with(hero_x: 30), 1)

    assert_equal 4, player[:room]
    assert_equal 31, player[:hero_x]
  end

  def test_a_setting_given_on_a_call_beside_the_handles_others_is_added
    game = Room.game.with_settings(room: 5)
    player = game_player.run(game.program(console: game_console, settings: { hero_x: 20 }), frames: 1)

    assert_equal 5, player[:room]
    assert_equal 21, player[:hero_x]
  end

  def test_a_setting_given_on_a_call_and_on_the_handle_is_refused
    game = Room.game.with_settings(room: 5)

    error = assert_raises(ArgumentError) { game.program(console: game_console, settings: { "room" => 6 }) }
    assert_match(/:room/, error.message)
    assert_match(/with_settings/, error.message)
  end

  def test_two_handles_differing_only_in_settings_are_two_programs
    game = Room.game

    assert_equal 2, played(game.with_settings(room: 2), 1)[:room]
    assert_equal 7, played(game.with_settings(room: 7), 1)[:room]
    assert_equal 1, played(game, 1)[:room]
  end
end
