# frozen_string_literal: true

require "test_helper"

# The bounce verb: a number that has reached either end of a range turns its speed round, so a
# ball that walks into a wall comes back off it. It only changes the speed; the number itself
# stays where it is. These tests play small games and read what they leave behind.
class TestBounce < Minitest::Test
  # Build through the DSL and play it, returning the player (read a variable with i[:name]).
  private def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    game_player.run(builder.program)
  end

  # Build the game without playing it, for the mistakes refused as it is built.
  private def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # ---- one turn at each end ----

  def test_at_the_low_end_a_speed_going_down_turns_up
    i = interpret do
      x = var :x, 0
      dx = var :dx, -3
      x.bounce! dx, 0..100
    end

    assert_equal 3, i[:dx]
    assert_equal 0, i[:x], "the number itself is not moved"
  end

  def test_at_the_high_end_a_speed_going_up_turns_down
    i = interpret do
      x = var :x, 100
      dx = var :dx, 3
      x.bounce! dx, 0..100
    end

    assert_equal(-3, i[:dx])
  end

  def test_past_an_end_it_still_turns
    i = interpret do
      x = var :x, 104
      dx = var :dx, 5
      x.bounce! dx, 0..100
    end

    assert_equal(-5, i[:dx])
  end

  # Already leaving the wall: a speed that points away from it is left as it is, so a ball that
  # sits on the wall for two passes does not rattle back into it.
  def test_a_speed_already_leaving_the_end_is_left_alone
    i = interpret do
      low = var :low, 0
      low_speed = var :low_speed, 2
      high = var :high, 100
      high_speed = var :high_speed, -2
      low.bounce! low_speed, 0..100
      high.bounce! high_speed, 0..100
    end

    assert_equal [2, -2], [i[:low_speed], i[:high_speed]]
  end

  def test_inside_the_range_nothing_changes
    i = interpret do
      x = var :x, 50
      dx = var :dx, -3
      hits = var :hits, 0
      x.bounce!(dx, 0..100) { hits += 1 }
    end

    assert_equal [50, -3, 0], [i[:x], i[:dx], i[:hits]]
  end

  # ---- a ball walking between two walls ----

  # From 10 at a speed of 4 between 0 and 20: 14, 18, 22 turns (hit 1), 18, 14, 10, 6, 2, -2
  # turns (hit 2), 2, 6. Eleven passes, two hits, and it ends at 6 heading up.
  def test_a_walking_value_turns_at_each_wall_and_the_block_runs_once_per_hit
    i = interpret do
      x = var :x, 10
      dx = var :dx, 4
      hits = var :hits, 0
      passes = var :passes, 0
      game_loop do
        x += dx
        x.bounce!(dx, 0..20) { hits += 1 }
        passes += 1
        halt if passes >= 11
      end
    end

    assert_equal [6, 4, 2], [i[:x], i[:dx], i[:hits]]
  end

  # ---- the ends of the range ----

  def test_the_ends_may_be_game_numbers
    i = interpret do
      right = var :right, 40
      x = var :x, 45
      dx = var :dx, 2
      x.bounce! dx, 0..right
    end

    assert_equal(-2, i[:dx])
  end

  def test_the_speed_may_be_a_pool_field
    i = interpret do
      turned = var :turned, 0
      balls = pool :ball, x: 0, dx: 0, capacity: 2
      balls.spawn x: 100, dx: 3
      balls.each { |ball| ball.x.bounce! ball.dx, 0..100 }
      balls.each { |ball| turned = ball.dx }
    end

    assert_equal(-3, i[:turned])
  end

  # ---- mistakes ----

  def test_a_speed_that_is_not_a_variable_is_refused
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        dx = var :dx, 2
        x.bounce! dx * 2, 0..100
      end
    end
    assert_match(/speed/, err.message)
    assert_match(/variable/, err.message)
  end

  def test_a_plain_number_for_the_speed_is_refused
    err = assert_raises(ArgumentError) { tree { var(:x, 0).bounce! 2, 0..100 } }
    assert_match(/variable/, err.message)
  end

  def test_a_range_that_is_not_a_range_is_refused
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        dx = var :dx, 2
        x.bounce! dx, 100
      end
    end
    assert_match(/range/, err.message)
  end

  # `0...100` stops short of 100, and a number that holds a fraction can be between 99 and 100,
  # so there is no one number to turn at. The two-dot range says the end exactly.
  def test_a_range_that_leaves_out_its_end_is_refused
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        dx = var :dx, 2
        x.bounce! dx, 0...100
      end
    end
    assert_match(/0\.\.100/, err.message)
  end

  def test_a_range_without_both_ends_is_refused
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        dx = var :dx, 2
        x.bounce! dx, 0..
      end
    end
    assert_match(/range/, err.message)
  end
end
