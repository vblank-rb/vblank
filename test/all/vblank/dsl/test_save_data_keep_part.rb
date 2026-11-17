# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_save_data"

# A SAVE OF ALL OF PLAY IN ONE WORD: `keep part: :play` keeps every variable, list and pool the part
# declares, as `start_over :play` puts them back, so a game can save in the middle of play and carry
# on after the power goes off without naming each of its hundreds of numbers.
class TestSaveDataKeepPart < Minitest::Test
  include SaveDataGames

  # Play is a score, a narrow count of lives, a trail and a pool of balls, the last declared after
  # the record, as an object of the game declares its own state after the save is set up. The best
  # score is a save_var and the music setting is left out of the part. A saves, B changes play
  # without saving; it loads what is saved as it boots.
  private def play_game
    built do
      screen :tiled, backdrop: :black
      best = save_var :best, 0
      music = var :music, 1
      game = save_data(:game) { keep part: :play }
      saves_keep_everything except: %i[music]
      part :play
      score = var :score, 0
      lives = var :lives, 3, width: :byte
      trail = list :trail, capacity: 4, width: :byte
      balls = pool :ball, x: 0, speed: 0, capacity: 3
      game[0].load
      game_loop do
        if pressed(:a)
          score = 50
          lives = 1
          trail.push 9
          balls.spawn(x: 12, speed: 3)
          best = 50
          music = 0
          game[0].save
        end
        if pressed(:b)
          score = 7
          lives = 2
        end
      end
    end
  end

  def test_all_of_play_comes_back_after_the_power_goes_off
    store = SaveImage.new
    play(play_game, store, pressing: { 2 => :a, 5 => :b })
    back = play(play_game, store)

    assert_equal [50, 1], [back[:score], back[:lives]]
    assert_equal [9], back.list(:trail)
    assert_equal [12], back.pool(:ball, :x).compact
    assert_equal 1, back[:music], "what is not in the part is not kept"
  end

  # Play is in a part and a scene both, and the record keeps the part twice, the scene, and one
  # field of a pool the part keeps whole: each thing is kept once. A saves, from the scene.
  private def overlapping_game
    built do
      screen :tiled, backdrop: :black
      mode = var :mode, :level
      game = save_data(:game) { keep part: :play }
      part :play
      balls = pool :ball, x: 0, capacity: 2
      game.keep balls.field(:x)
      game.keep part: :play
      game.keep part: :level
      scene :level do
        hp = var :hp, 5
        if pressed(:a)
          hp = 9
          balls.spawn(x: 4)
          game[0].save
        end
      end
      game[0].load
      game_loop { call mode }
    end
  end

  def test_a_thing_kept_through_two_parts_or_twice_is_kept_once
    store = SaveImage.new
    play(overlapping_game, store, pressing: { 2 => :a })
    back = play(overlapping_game, store)

    assert_equal 9, back[:hp]
    assert_equal [4], back.pool(:ball, :x).compact
  end

  # A timer inside the part is kept with it; +timers_before+ more, outside the part and declared
  # first, are the change a later version of the game makes elsewhere.
  private def timed_game(timers_before)
    built do
      screen :tiled, backdrop: :black
      ticks = var :ticks, 0
      timers_before.times { every(40) { ticks += 1 } }
      game = save_data(:game) { keep part: :play }
      part :play
      score = var :score, 0
      every(50) { score += 1 }
      game[0].load
      game_loop do
        if pressed(:a)
          score = 30
          game[0].save
        end
      end
    end
  end

  def test_a_timer_added_outside_the_part_leaves_old_saves_loading
    store = SaveImage.new
    play(timed_game(0), store, pressing: { 2 => :a })

    assert_equal 30, play(timed_game(1), store)[:score]
  end

  # A job in the part saves from inside its own step, then stops; after a load, starting it takes
  # its first step on that pass, as a start always does. +seen+ is the count just after the start.
  private def job_game
    built do
      screen :tiled, backdrop: :black
      seen = var :seen, 0
      game = save_data(:game) { keep part: :play }
      part :play
      count = var :count, 0
      job = each_pass(:tick) do |me|
        count += 1
        me.stop
        game[0].save
      end
      game[0].load
      game_loop do
        if pressed(:a)
          job.start
          seen = count
        end
      end
    end
  end

  def test_a_save_made_inside_a_step_starts_the_job_again_on_its_first_step
    store = SaveImage.new
    play(job_game, store, pressing: { 2 => :a })
    back = play(job_game, store, pressing: { 3 => :a })

    assert_equal 2, back[:seen]
  end

  # A narrow variable is kept by a `keep` of its own, as by a part.
  def test_a_narrow_variable_kept_on_its_own_comes_back
    game = lambda do
      built do
        screen :tiled, backdrop: :black
        lives = var :lives, 3, width: :byte
        save = save_data(:game) { keep lives }
        save[0].load
        game_loop do
          if pressed(:a)
            lives = -2
            save[0].save
          end
        end
      end
    end
    store = SaveImage.new
    play(game.call, store, pressing: { 2 => :a })

    assert_equal(-2, play(game.call, store)[:lives])
  end

  def test_a_part_no_one_declared_is_refused_naming_it
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        save_data(:game) { keep part: :plya }
        part :play
        var :score, 0
        game_loop { nil }
      end
    end

    assert_match "part: :plya", error.message
    assert_match "part :play", error.message, "it lists the parts the game has"
  end

  def test_a_variable_of_the_part_kept_by_another_record_is_refused
    error = assert_raises(ArgumentError) do
      built do
        screen :tiled
        part :play
        score = var :score, 0
        part :settings
        save_data(:game) { keep part: :play }
        save_data(:scores) { keep score }
        game_loop { nil }
      end
    end

    assert_match "keeps it too", error.message
  end
end
