# frozen_string_literal: true

require "test_helper"
require "first_pass_presses"

# A NEW GAME: `part :play` says that what the game declares from that line on is its play, and
# `start_over :play` puts all of it back as it was declared, on the pass the new game starts.
# What the game keeps between games stays as it is: a high score kept with save_var, the
# random numbers, and whatever was declared outside the part.
#
# The Advance's cartridge playing the same game in the emulator is in
# test/lowering/gba/vblank/builder/test_parts_cartridge.rb.

# The game both files play, and how they play it.
module PartGames
  include FirstPassPresses

  # A SMALL GAME THAT ENDS AND STARTS AGAIN. A plays: the score, the lives, a speed with a
  # fraction, the state, a list, a list that starts full and a pool all change, and a number
  # is rolled. B is game over: the best score is kept, and a new game starts. The best score is
  # declared above the part, and the part ends at `part :between_games`, so what is declared
  # before and after it is kept between games.
  private def game_that_starts_again
    built do
      screen :tiled
      best = var :best, 0
      part :play
      score = var :score, 0
      lives = var :lives, 3, width: :byte
      speed = var :speed, 1.5
      state = var :state, :playing
      trail = list :trail, capacity: 4, width: :byte
      marks = list :marks, capacity: 3, full_of: 7
      sparks = pool :spark, x: 0, capacity: 3
      part :between_games
      games = var :games, 1
      first_roll = var :first_roll, 0
      next_roll = var :next_roll, 0
      # The list, the full list and the pool in one number, for a reader that sees variables only.
      shape = var :shape, 0
      game_loop do
        shape = trail.length + (marks[0] * 10) + (sparks.count * 100)
        if pressed(:a)
          score += 50
          lives -= 1
          speed += 1.0
          state = :over
          trail.push 9
          marks[0] = 2
          sparks.spawn(x: 5)
          rolled = rand(1..1000)
          if first_roll == 0
            first_roll = rolled
          else
            next_roll = rolled
          end
        end
        if pressed(:b)
          best = score if score > best
          games += 1
          start_over :play
        end
      end
    end
  end

  private def built(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # Each button on a frame of its own, two apart: frame number => button.
  private def presses(*buttons) = buttons.each_with_index.to_h { |button, i| [(i * 2) + 2, button] }

  # The game played with +buttons+, counted from the game's first pass.
  private def played(program, *buttons)
    game_player(save: VBlank::IR::SaveImage.new).input_each_frame(&presses_from_first_pass(presses(*buttons)))
                                    .run(program, frames: (buttons.length * 2) + 6)
  end

  PLAY_VARIABLES = %i[score lives speed state].freeze
end

class TestParts < Minitest::Test
  include PartGames

  def test_start_over_puts_the_play_back_as_declared
    fresh = played(game_that_starts_again)
    again = played(game_that_starts_again, :a, :b)

    assert_equal PLAY_VARIABLES.map { |name| fresh[name] }, PLAY_VARIABLES.map { |name| again[name] }
    assert_empty again.list(:trail)
    assert_equal [7, 7, 7], again.list(:marks)
    assert_empty again.pool(:spark, :x).compact
  end

  def test_start_over_leaves_what_is_kept_between_games
    again = played(game_that_starts_again, :a, :b)

    assert_equal 50, again[:best], "declared above the part"
    assert_equal 2, again[:games], "declared below the part"
  end

  # A save_var keeps its number between games even where a part declares it.
  def test_start_over_leaves_a_save_var_in_the_part_alone
    run = played(built do
      screen :tiled
      part :play
      best = save_var :best, 0
      score = var :score, 0
      game_loop do
        if pressed(:a)
          score += 50
          best = score
        end
        start_over :play if pressed(:b)
      end
    end, :a, :b)

    assert_equal [0, 50], [run[:score], run[:best]]
  end

  # A new game is not a replay: the random numbers roll on from where the last game left them.
  def test_start_over_leaves_the_random_numbers_rolling_on
    again = played(game_that_starts_again, :a, :b, :a)

    refute_equal 0, again[:first_roll]
    refute_equal again[:first_roll], again[:next_roll]
  end

  # The second game plays as the first did: the pool spawns into its first slot again.
  def test_the_next_game_plays_after_start_over
    first = played(game_that_starts_again, :a)
    second = played(game_that_starts_again, :a, :b, :a)

    assert_equal first.pool(:spark, :x).compact, second.pool(:spark, :x).compact
    assert_equal [9], second.list(:trail)
    assert_equal first[:score], second[:score]
  end

  # With a block, the part is what the block declares, and nothing after it.
  def test_a_part_given_a_block_ends_with_the_block
    run = played(built do
      screen :tiled
      part(:play) { var :score, 0 }
      kept = var :kept, 0
      score = var :score, 0
      game_loop do
        if pressed(:a)
          score += 5
          kept += 5
        end
        start_over :play if pressed(:b)
      end
    end, :a, :b)

    assert_equal [0, 5], [run[:score], run[:kept]]
  end

  # A scene names a part too: what its body declares.
  def test_start_over_takes_the_name_of_a_scene
    run = played(built do
      screen :tiled
      mode = var :mode, :level
      scene :level do
        steps = var :steps, 4
        steps += 1 if pressed(:a)
        start_over :level if pressed(:b)
      end
      game_loop { call mode }
    end, :a, :a, :b)

    assert_equal 4, run[:steps]
  end

  private def refused(&block)
    assert_raises(ArgumentError) { built { screen :tiled; instance_eval(&block) } }.message
  end

  def test_an_unknown_part_is_a_friendly_error
    message = refused do
      part :play
      var :score, 0
      game_loop { start_over :ply }
    end
    assert_match(/no part or scene :ply/, message)
    assert_match(/:play/, message)
  end

  def test_naming_a_save_var_is_a_friendly_error
    message = refused do
      save_var :best, 0
      game_loop { start_over :best }
    end
    assert_match(/:best is a save_var/, message)
  end

  def test_naming_a_variable_is_a_friendly_error
    message = refused do
      part :play
      var :score, 0
      game_loop { start_over :score }
    end
    assert_match(/:score is a variable/, message)
    assert_match(/part :play/, message)
  end

  def test_start_over_with_no_name_is_a_friendly_error
    message = refused { game_loop { start_over } }
    assert_match(/start_over needs the name of a part/, message)
  end
end
