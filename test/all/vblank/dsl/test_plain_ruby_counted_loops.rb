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

  private def repeats_in(program) = program.walk.count { |node| node.kind == :repeat }

  # Five boxes a round, sixteen rounds: written out they are far past what the build writes out
  # (Counts::KnownRounds::WRITTEN_OUT_MOST), so the build makes them one loop, as `repeat` does.
  def test_a_large_body_counted_sixteen_times_is_a_loop_no_bigger_than_repeat
    counted = built do
      game_loop do
        clear_screen :black
        16.times do |i|
          draw_rect_at i * 9, 10, 4, 4, :red
          draw_rect_at i * 9, 30, 4, 4, :green
          draw_rect_at (i * 9) + 2, 50, 4, 4, :blue
          draw_rect_at 4, 60 + (i * 4), 2, 2, :white
          draw_rect_at 150 - (i * 3), 130, 2, 2, :yellow
        end
      end
    end
    repeated = built do
      game_loop do
        clear_screen :black
        repeat(16) do |i|
          draw_rect_at i * 9, 10, 4, 4, :red
          draw_rect_at i * 9, 30, 4, 4, :green
          draw_rect_at (i * 9) + 2, 50, 4, 4, :blue
          draw_rect_at 4, 60 + (i * 4), 2, 2, :white
          draw_rect_at 150 - (i * 3), 130, 2, 2, :yellow
        end
      end
    end

    assert_equal 1, repeats_in(counted), "the sixteen rounds are one loop"
    assert_operator counted.walk.count, :<=, repeated.walk.count, "no bigger than the same game written with repeat"
    shown = game_player.run(counted, frames: 2).screen
    [[0, 10, :red], [15 * 9, 30, :green], [(7 * 9) + 2, 50, :blue], [4, 60 + 60, :white], [150 - 45, 130, :yellow]]
      .each { |x, y, color| assert_equal Color.resolve(color), shown.pixel(x, y), "the box at #{x}, #{y}" }
  end

  def test_a_two_line_body_counted_four_times_is_written_out
    program = built do
      game_loop do
        clear_screen :black
        4.times do |i|
          draw_rect_at 10 + (i * 20), 10, 8, 8, :blue
          draw_rect_at 10 + (i * 20), 30, 8, 8, :red
        end
      end
    end

    assert_equal 0, repeats_in(program), "four small rounds stay written out"
    shown = game_player.run(program, frames: 2).screen
    assert_equal [Color.resolve(:blue)] * 4, [10, 30, 50, 70].map { |x| shown.pixel(x, 10) }
  end

  # Each round draws in another colour, picked while building: the rounds differ in more than a
  # number counted up, so however many there are they stay written out.
  def test_rounds_that_differ_in_more_than_a_number_stay_written_out
    colors = %i[red green blue white]
    program = built do
      game_loop do
        clear_screen :black
        16.times do |i|
          draw_rect_at i * 9, 10, 4, 4, colors[i % 4]
          draw_rect_at i * 9, 30, 4, 4, colors[(i + 1) % 4]
          draw_rect_at i * 9, 50, 4, 4, colors[(i + 2) % 4]
        end
      end
    end

    assert_equal 0, repeats_in(program)
    shown = game_player.run(program, frames: 2).screen
    assert_equal %i[red green blue white red].map { |color| Color.resolve(color) },
                 (0..4).map { |i| shown.pixel(i * 9, 10) }
  end

  # A counted loop inside another: the inner one is a loop in each outer round, and the outer
  # rounds, alike but for their numbers and their inner loop's counter, are a loop too.
  def test_a_counted_loop_inside_a_counted_loop
    program = built do
      total = 0
      game_loop do
        total = 0
        8.times do |row|
          16.times do |column|
            total += (row * 100) + column
            total += 1
            total -= 1
            total += column - column
          end
        end
      end
    end

    assert_equal 2, repeats_in(program), "a loop in a loop"
    total = game_player.run(program, frames: 2)[:total]
    assert_equal (0...8).sum { |row| (0...16).sum { |column| (row * 100) + column } }, total
  end

  # Every counting form on plain numbers chooses the same way: these are each large enough to loop.
  def test_each_counting_form_on_plain_numbers_is_a_loop_when_large
    program = built do
      a = 1
      ups = downs = steps = ranged = fors = 0
      game_loop do
        a += 1 if pressed(:a)
        ups = downs = steps = ranged = fors = 0
        2.upto(17) { |i| ups += (i * a) + 1; ups -= 1; ups += i - i }
        17.downto(2) { |i| downs += (i * a) + 1; downs -= 1; downs += i - i }
        0.step(45, 3) { |i| steps += (i * a) + 1; steps -= 1; steps += i - i }
        (0...16).each { |i| ranged += (i * a) + 1; ranged -= 1; ranged += i - i }
        for i in 0..15
          fors += (i * a) + 1
          fors -= 1
          fors += i - i
        end
      end
    end

    assert_equal 5, repeats_in(program)
    player = game_player.run(program, frames: 2)
    ruby = { ups: (2..17).sum, downs: (2..17).sum, steps: 0.step(45, 3).sum, ranged: (0...16).sum, fors: (0..15).sum }
    assert_equal ruby, ruby.keys.to_h { |name| [name, player[name]] }
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
