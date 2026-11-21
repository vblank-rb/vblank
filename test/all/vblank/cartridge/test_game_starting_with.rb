# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_features"

# A game started in a chosen state: `game.starting_with(mode: :playing, steps: 40, trail: [5, 6])`
# is the same game with those variables and lists starting where the test chose, so a test plays
# from the moment it asks about without playing to it and without the game keeping a save. It is
# the program built with other starts, so every run plays it and each checks it against the
# interpreter started the same way. The game is the cave of test/all/vblank/builder/test_features.rb.
class TestGameStartingWith < Minitest::Test
  Cave = TestFeatures::Cave

  private def played(game, frames) = game_player.run(game.program(console: game_console), frames: frames)

  def test_a_game_started_in_a_chosen_state_plays_on_from_it
    player = played(Cave.game.starting_with(mode: :playing, steps: 40, trail: [5, 6], hero_x: 100), 2)

    assert_equal [5, 6, 41, 42], player.list(:trail)
    assert_equal 102, player[:hero_x]
    assert_equal Cave.flown([41, 42]), player[:bat_x]
  end

  def test_a_game_with_no_chosen_start_starts_as_declared
    player = played(Cave.game, 2)

    assert_empty player.list(:trail)
    assert_equal 2, player[:steps]
  end

  def test_starts_and_features_go_together
    small = Cave.game.with_features(:bat).starting_with(mode: :playing).starting_with(bat_x: 1)

    assert_equal 1 + Cave.flown([1]), played(small, 1)[:bat_x]
  end

  def test_a_start_for_something_the_game_does_not_declare_is_refused
    game = Cave.game.with_features(:bat).starting_with(hero_x: 3)

    error = assert_raises(ArgumentError) { game.program(console: game_console) }
    assert_match(/no variable or list :hero_x/, error.message)
  end

  def test_a_list_started_with_more_than_it_holds_is_refused
    game = Cave.game.starting_with(trail: (1..9).to_a)

    error = assert_raises(ArgumentError) { game.program(console: game_console) }
    assert_match(/holds 8/, error.message)
  end

  def test_a_start_of_the_wrong_kind_is_refused
    error = assert_raises(ArgumentError) { Cave.game.starting_with(steps: [1]).program(console: game_console) }
    assert_match(/:steps is a variable/, error.message)
  end

  # The chosen start is the build's start: a new game puts the part back where the build started it,
  # a list holding its chosen items however its declaration fills it. Two passes: the first changes
  # both, the second changes them and starts the part over.
  module Restart
    def self.game
      VBlank.game("RESTART", consoles: %i[gba gbc snes genesis ps1]) do
        screen :bitmap
        passes = var :_passes, 0
        part :play
        lives = var :lives, 3
        trail = list :trail, capacity: 4, full_of: 3
        game_loop do
          passes += 1
          lives -= 1
          trail[0] = 9
          start_over :play if passes == 2
        end
      end
    end
  end

  def test_starting_over_puts_back_the_chosen_start
    player = played(Restart.game.starting_with(lives: 7, trail: [5, 6]), 2)

    assert_equal 7, player[:lives]
    assert_equal [5, 6], player.list(:trail)
  end

  # A save record's new game puts its kept things back where the build started them too.
  def test_a_save_records_new_game_puts_back_the_chosen_start
    game = VBlank.game("RESET", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      passes = var :_passes, 0
      lives = var :lives, 3
      trail = list :trail, capacity: 4, full_of: 3
      files = save_data(:file, copies: 1) { keep lives, trail }
      game_loop do
        passes += 1
        lives -= 1
        trail[0] = 9
        files.reset if passes == 2
      end
    end
    player = played(game.starting_with(lives: 7, trail: [5, 6]), 2)

    assert_equal 7, player[:lives]
    assert_equal [5, 6], player.list(:trail)
  end

  # A play scene that declares where the hero stands. A `var` line's start is set once at power-on
  # wherever it is written, so the scene's variables are the game's from the start, and a chosen start
  # stands in for the declared one as it does for a variable declared at the top. The title hands over
  # on its second pass; play draws the hero and walks him a pixel a pass.
  module Play
    GREEN = VBlank::Graphics::Color.resolve(:green)

    def self.game
      VBlank.game("PLAY", consoles: %i[gba gbc snes genesis ps1]) do
        screen :bitmap
        mode = var :mode, :title
        scene :title do
          waited = var :waited, 0
          waited += 1
          mode = :playing if waited == 2
        end
        scene :playing do
          hero_x = var :hero_x, 10
          hero_y = var :hero_y, 20
          clear_screen :black
          fill_rect hero_x, hero_y, 4, 4, :green
          hero_x += 1
        end
        game_loop { call mode }
      end
    end
  end

  def test_a_variable_a_scene_declares_starts_where_chosen
    player = played(Play.game.starting_with(mode: :playing, hero_x: 88, hero_y: 40), 1)

    assert_equal Play::GREEN, player.screen.pixel(88, 40), "the first frame of the scene shows the hero there"
    assert_equal 0, player.screen.pixel(10, 20)
    assert_equal 89, player[:hero_x]
  end

  def test_a_variable_a_scene_declares_is_set_once_and_not_again_as_the_scene_starts
    player = played(Play.game.starting_with(hero_x: 88), 3)

    assert_equal 89, player[:hero_x], "play began on the third pass and moved him once"
  end

  def test_a_variable_a_routine_declares_starts_where_chosen
    game = VBlank.game("ROUTINE", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      func :step do
        steps = var :steps, 0
        steps += 1
      end
      game_loop { call :step }
    end

    assert_equal 12, played(game.starting_with(steps: 10), 2)[:steps]
  end

  def test_a_start_for_a_list_a_scene_makes_each_time_it_starts_is_refused
    game = VBlank.game("SCENES", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      mode = var :mode, :level
      scene :level do
        screen :bitmap
        bag = list :bag, capacity: 2
        bag.push 1
      end
      game_loop { call mode }
    end

    error = assert_raises(ArgumentError) { game.starting_with(bag: [4]).program(console: game_console) }
    assert_match(/the scene :level/, error.message)
  end

  def test_a_start_that_is_no_name_the_variable_is_given_is_refused
    error = assert_raises(ArgumentError) { Cave.game.starting_with(mode: :playin).program(console: game_console) }

    assert_match(/:playin/, error.message)
    assert_match(/:title, :playing/, error.message)
  end

  def test_a_start_for_a_saved_variable_is_refused_saying_how_to_start_it
    game = VBlank.game("SAVED", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      save_var :best, 0
      game_loop { wait_vblank }
    end

    error = assert_raises(ArgumentError) { game.starting_with(best: 5).program(console: game_console) }
    assert_match(/saved variable/, error.message)
    assert_match(/save/, error.message)
  end
end
