# frozen_string_literal: true

require "test_helper"

# Ruby's counting loops (`n.times`, `upto`, `downto`, `step`, a range's `each`, `for`) over a
# number the game keeps: each is a loop the game runs as it plays, going round as many times as
# Ruby's would. The answer key is Ruby itself, the same lines run on Integers.
class TestPlainRubyCountedLoops < Minitest::Test
  Refused = VBlank::DSL::PlainRuby::Refused

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    builder.program
  end

  private def played(frames: 2, &block) = game_player.run(built(&block), frames: frames)

  def test_times_over_a_game_number_draws_one_box_per_life_on_every_pass
    program = built do
      lives = 3
      game_loop do
        clear_screen :black
        lives -= 1 if pressed(:a)
        lives.times { |i| draw_rect_at 10 + (i * 20), 10, 8, 8, :blue }
      end
    end
    before = game_player.run(program, frames: 2).screen
    after = game_player.input_each_frame { [:a] }.run(program, frames: 3).screen

    boxes = ->(screen) { [10, 30, 50, 70].map { |x| screen.pixel(x, 10) == Color.resolve(:blue) } }
    assert_equal [true, true, true, false], boxes.call(before), "three lives, three boxes"
    assert_equal [true, true, false, false], boxes.call(after), "one life lost, two boxes"
  end

  def test_each_counting_form_goes_round_as_often_as_ruby
    player = played do
      a = 3
      times = 0
      up = 0
      up_late = 0
      down = 0
      upto_none = 0
      exclusive = 0
      inclusive = 0
      stepped = 0
      game_loop do
        a += 1 if pressed(:a)
        times = 0
        up = 0
        up_late = 0
        down = 0
        upto_none = 0
        exclusive = 0
        inclusive = 0
        stepped = 0
        a.times { |i| times += i + 1 }
        0.upto(a) { |i| up += i + 1 }
        1.upto(a) { |i| up_late += i }
        a.downto(1) { |i| down = (down * 10) + i }
        5.upto(a) { upto_none += 1 }
        (0...a).each { |i| exclusive += i + 1 }
        (0..a).each { |i| inclusive += i + 1 }
        0.step(a * 3, 2) { |i| stepped = (stepped * 10) + i }
      end
    end

    # 0.step(9, 2) is 0, 2, 4, 6 and 8, each written as a digit.
    ruby = { times: 6, up: 10, up_late: 6, down: 321, upto_none: 0, exclusive: 6, inclusive: 10, stepped: 2468 }
    assert_equal ruby, ruby.keys.to_h { |name| [name, player[name]] }
  end

  # A name given a plain number before the loop and changed in it changes on every round the game
  # goes, though the loop starts at a number written out.
  def test_a_name_changed_in_the_loop_follows_every_round
    player = played do
      a = 3
      up = 0
      ranged = 0
      counted = 0
      game_loop do
        x = 0
        0.upto(a) { x += 2 }
        up = x
        y = 0
        (1..a).each { y += 2 }
        ranged = y
        z = 0
        a.times { z += 2 }
        counted = z
      end
    end

    assert_equal [8, 6, 6], [player[:up], player[:ranged], player[:counted]]
  end

  # A name set before the game loop and changed only inside a counting loop in it.
  def test_a_name_changed_only_in_the_loop_keeps_growing_every_pass
    player = played(frames: 2) do
      a = 3
      up = 0
      ranged = 0
      game_loop do
        0.upto(a) { up += 2 }
        (0...a).each { ranged += 1 }
      end
    end

    assert_equal [16, 6], [player[:up], player[:ranged]]
  end

  def test_for_over_a_range_to_a_game_number_is_a_loop_the_game_runs
    player = played do
      n = 3
      total = 0
      from = 0
      game_loop do
        total = 0
        for each_number in 0...n
          total += each_number + 1
        end
        from = 0
        for each_number in n..5
          from = (from * 10) + each_number
        end
      end
    end

    assert_equal [6, 345], [player[:total], player[:from]]
  end

  def test_the_count_and_the_start_are_read_once_as_ruby_reads_them
    player = played do
      a = 3
      b = 1
      rounds = 0
      seen = 0
      game_loop do
        a = 3
        b = 1
        rounds = 0
        seen = 0
        a.times { a += 1; rounds += 1 }
        b.upto(4) { |i| b += 10; seen += i }
      end
    end

    assert_equal [3, 10], [player[:rounds], player[:seen]]
  end

  def test_a_range_to_a_game_number_refuses_what_it_cannot_go_over
    error = assert_raises(Refused) do
      built do
        n = 3
        total = 0
        game_loop do
          (0...n).map { |i| total += i }
          n += 1
        end
      end
    end
    assert_includes error.message, "`each`"
  end

  def test_a_step_the_game_works_out_is_refused
    error = assert_raises(Refused) do
      built do
        n = 3
        by = 1
        total = 0
        game_loop do
          0.step(10, by) { |i| total += i }
          by += 1
          n += 1
        end
      end
    end
    assert_includes error.message, "step"
  end
end
