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
      screen :tiled, backdrop: :black
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
      screen :tiled, backdrop: :black
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
      screen :tiled, backdrop: :black
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
      screen :tiled, backdrop: :black
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

  # A routine written while a part is in force is in the part, though its body is built later.
  def test_a_func_and_a_scene_written_after_part_are_in_it
    run = played(built do
      screen :tiled, backdrop: :black
      mode = var :mode, :level
      part :play
      func(:tally) do
        coins = var :coins, 0
        coins += 1
      end
      scene :level do
        steps = var :steps, 4
        if pressed(:a)
          steps += 1
          call :tally
        end
        start_over :play if pressed(:b)
      end
      game_loop { call mode }
    end, :a, :a, :b)

    assert_equal [4, 0], [run[:steps], run[:coins]]
  end

  # A routine written inside a scene is the scene's, as its body's own lines are.
  def test_a_func_written_inside_a_scene_is_in_the_scene
    run = played(built do
      screen :tiled, backdrop: :black
      mode = var :mode, :level
      scene :level do
        func(:tally) do
          coins = var :coins, 0
          coins += 1
        end
        call :tally if pressed(:a)
        start_over :level if pressed(:b)
      end
      game_loop { call mode }
    end, :a, :a, :b)

    assert_equal 0, run[:coins]
  end

  # `after` counts again from the new game, so it fires in the second game too.
  def test_after_fires_again_in_the_next_game
    run = played(built do
      screen :tiled, backdrop: :black
      fired = var :fired, 0
      part :play
      game_loop do
        after(2) { fired += 1 }
        start_over :play if pressed(:b)
      end
    end, :a, :a, :b)

    assert_equal 2, run[:fired]
  end

  # A job of `each_pass` that the last game started is stopped in the new one.
  def test_a_running_each_pass_job_stops_in_the_next_game
    run = played(built do
      screen :tiled, backdrop: :black
      ticks = var :ticks, 0
      part :play
      each_pass(:count) { |_job| ticks += 1 }
      game_loop do
        each_pass(:count).start if pressed(:a)
        start_over :play if pressed(:b)
      end
    end, :a, :b)
    stopped = run[:ticks]
    longer = played(built do
      screen :tiled, backdrop: :black
      ticks = var :ticks, 0
      part :play
      each_pass(:count) { |_job| ticks += 1 }
      game_loop do
        each_pass(:count).start if pressed(:a)
        start_over :play if pressed(:b)
      end
    end, :a, :b, :up)

    assert_equal stopped, longer[:ticks], "no tick after the new game"
  end

  # A sprite goes back to its `at:` and shows as declared. On a tiled screen the console draws it.
  def test_a_sprite_goes_back_to_where_it_was_declared
    run = played(built do
      screen :tiled
      image(:ball, "#" => :white) { "########\n" * 8 }
      at_x = var :at_x, 0
      at_y = var :at_y, 0
      part :play
      ball = sprite :ball, at: [10, 20]
      game_loop do
        ball.move_to(50, 60) if pressed(:a)
        start_over :play if pressed(:b)
        at_x = ball.x
        at_y = ball.y
      end
    end, :a, :b)

    assert_equal [10, 20], [run[:at_x], run[:at_y]]
  end

  # On a bitmap screen the game paints the sprite: it is painted at its `at:` again, and
  # what it covered where it stood is put back.
  def test_a_painted_sprite_goes_back_and_its_last_place_is_cleaned
    run = played(built do
      screen :bitmap
      clear_screen :blue
      image(:ball, "#" => :red) { "####\n" * 4 }
      part :play
      ball = sprite :ball, at: [10, 20]
      game_loop do
        ball.move_to(50, 60) if pressed(:a)
        start_over :play if pressed(:b)
      end
    end, :a, :b)

    assert_equal Color.resolve(:red), run.screen.pixel(11, 21)
    assert_equal Color.resolve(:blue), run.screen.pixel(51, 61)
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

  def test_a_part_named_like_a_scene_is_a_friendly_error
    message = refused do
      part :level
      var :score, 0
      scene(:level) { var :steps, 0 }
    end
    assert_match(/part :level and scene :level/, message)
  end

  def test_a_name_that_cannot_name_a_part_is_a_friendly_error
    message = refused { part :"two words" }
    assert_match(/cannot name a part/, message)
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
