# frozen_string_literal: true

require "test_helper"

# A loop that stops as soon as it has its answer.
#
# The shape this exists for is a search — a ray marching until it meets a wall. Written as a
# counted loop guarded by a flag, every step after the answer still runs: it tests the flag,
# branches, and does nothing. A ray that hits a third of the way through pays for the other two
# thirds, and a first-person view casts one of these per strip across the screen.
#
# Where the Advance's cartridge stops, and the shape its ARM loop takes, are in
# test/lowering/gba/vblank/builder/test_repeat_stop_when_cartridge.rb.

# The games both files play.
module RepeatStopWhenGames
  private def program(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def marching
    program do
      screen :bitmap
      hit = var :hit, 0
      steps = var :steps, 0
      game_loop do
        hit = 0
        steps = 0
        repeat(20, stop_when: hit == 1) do
          steps += 1
          hit = 1 if steps >= 5
        end
      end
    end
  end
end

class TestRepeatStopWhen < Minitest::Test
  include RepeatStopWhenGames

  def test_it_stops_the_pass_after_the_answer_arrives
    assert_equal 5, game_player.run(marching, frames: 2)[:steps]
  end

  def test_a_loop_with_nothing_to_stop_for_runs_its_whole_count
    run = game_player.run(program do
      screen :bitmap
      n = var :n, 0
      game_loop { n = 0; repeat(7) { n += 1 } }
    end, frames: 2)

    assert_equal 7, run[:n]
  end

  # Asked before the body, so a loop whose answer is already in runs the body no times — the
  # same reading on both backends, which is the part that has to be pinned.
  def test_a_condition_already_true_runs_the_body_no_times
    run = game_player.run(program do
      screen :bitmap
      done = var :done, 1
      n = var :n, 0
      game_loop { n = 0; repeat(9, stop_when: done == 1) { n += 1 } }
    end, frames: 2)

    assert_equal 0, run[:n]
  end
  private def rewritten(&block)
    b = VBlank::Builder.new
    b.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    b.finalize_program
    b.program
  end

  # A list read at a place the game works out makes the join keep its answer in a variable, which the
  # loop must work out again each round.
  def test_a_test_joined_by_or_stops_on_its_second_side
    program = rewritten do
      screen :bitmap
      xs = [3, 2, 0, 9, 9, 9, 9, 9]
      n = 0
      k = 0
      done = 0
      game_loop do
        xs[7] = 9 if pressed(:a) # game code changes it, so it is a list
        if done == 0
          n = 0
          k = 0
          repeat(8, stop_when: n > 100 || xs[k] == 0) do
            n += 1
            k += 1
          end
          done = 1
        end
      end
    end
    assert_equal 2, game_player.run(program, frames: 3)[:n]
  end

  def test_a_test_joined_by_and_stops_on_its_second_side
    program = rewritten do
      screen :bitmap
      xs = [3, 2, 0, 9, 9, 9, 9, 9]
      n = 0
      k = 0
      done = 0
      game_loop do
        xs[7] = 9 if pressed(:a) # game code changes it, so it is a list
        if done == 0
          n = 0
          k = 0
          repeat(8, stop_when: n < 100 && xs[k] == 0) do
            n += 1
            k += 1
          end
          done = 1
        end
      end
    end
    assert_equal 2, game_player.run(program, frames: 3)[:n]
  end
end
