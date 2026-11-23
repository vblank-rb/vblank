# frozen_string_literal: true

require "test_helper"

# `break` and `next` in a loop the game runs, a `while` or `until` on a test the game makes, a
# counting loop over a game number, `for` and `loop do`: each does what Ruby says. The answer
# key is Ruby itself, the same lines run on Integers.
class TestPlainRubyJumps < Minitest::Test
  Refused = VBlank::DSL::PlainRuby::Refused

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    builder.program
  end

  private def played(frames: 2, &block) = game_player.run(built(&block), frames: frames)

  def test_a_search_with_while_and_break_stops_at_the_first_match
    player = played do
      target = 3
      found = -1
      at = 0
      game_loop do
        found = -1
        at = 0
        while at < 10
          if at * at > target * 4
            found = at
            break
          end
          at += 1
        end
      end
    end

    assert_equal [4, 4], [player[:found], player[:at]]
  end

  def test_next_skips_the_rest_of_the_round
    player = played do
      n = 7
      at = 0
      total = 0
      game_loop do
        at = 0
        total = 0
        while at < n
          at += 1
          next if at.even?

          total += at
        end
      end
    end

    assert_equal 16, player[:total]
  end

  def test_break_and_next_in_one_until_loop
    player = played do
      n = 20
      at = 0
      total = 0
      game_loop do
        at = 0
        total = 0
        until at >= n
          at += 1
          next if at % 3 == 0
          break if at > 7

          total += at
        end
      end
    end

    # 1 + 2 + 4 + 5 + 7, then 8 leaves.
    assert_equal [19, 8], [player[:total], player[:at]]
  end

  def test_a_jump_on_the_right_of_and_or_or
    player = played do
      n = 20
      at = 0
      total = 0
      game_loop do
        at = 0
        total = 0
        while at < n
          at += 1
          at.odd? || next
          at > 9 && break
          total += at
        end
      end
    end

    # 1 + 3 + 5 + 7 + 9, then 11 leaves.
    assert_equal [25, 11], [player[:total], player[:at]]
  end

  def test_break_and_next_in_counting_loops_over_a_game_number
    player = played do
      n = 9
      timed = 0
      ranged = 0
      counted = 0
      looped = 0
      game_loop do
        timed = 0
        ranged = 0
        counted = 0
        looped = 0
        n.times do |i|
          next if i == 2
          break if i == 5

          timed += i
        end
        (0...n).each do |i|
          next if i.odd?

          ranged += i
        end
        for i in 0..n
          break if i * 2 > n

          counted += i
        end
        loop do
          looped += 1
          break if looped >= n
        end
      end
    end

    # 0 + 1 + 3 + 4; 0 + 2 + 4 + 6 + 8; 0 + 1 + 2 + 3 + 4; up to 9.
    assert_equal [8, 20, 10, 9], [player[:timed], player[:ranged], player[:counted], player[:looped]]
  end

  # A `loop do` whose jumps all sit under plain tests is Ruby's, run while building, in game
  # code too: here it takes build-time rolls until a 2 comes up, and the game shows how many.
  ROLLS = [5, 1, 4, 2, 3].freeze

  def test_loop_do_on_plain_values_runs_while_building
    player = played do
      shown = 0
      game_loop do
        dice = ROLLS.each_with_index
        taken = loop do
          roll, at = dice.next
          break at + 1 if roll == 2
        end
        shown = taken
      end
    end

    assert_equal 4, player[:shown]
  end

  # A loop's test that changes something is not asked again after a `break`, as in Ruby.
  def test_a_test_with_a_change_in_it_is_not_asked_after_a_break
    player = played do
      calls = 0
      at = 0
      most = 100
      game_loop do
        calls = 0
        at = 0
        while (calls += 1) < most
          at += 1
          break if at == 3
        end
      end
    end

    assert_equal [3, 3], [player[:calls], player[:at]]
  end

  # A `loop do` that a game test would make the game's, whose body reads a plain value that
  # changes on every round, cannot be a loop the game runs: the game would keep one round's value.
  def test_loop_do_reading_a_plain_value_that_changes_each_round_is_refused
    error = assert_raises(Refused) do
      built do
        most = 10
        total = 0
        game_loop do
          most += 1 if pressed(:a)
          total = 0
          steps = STEPS.each
          loop do
            total += steps.next
            break if total > most
          end
        end
      end
    end
    assert_includes error.message, "`loop do`"
  end

  STEPS = (1..100).to_a.freeze

  # Ruby's `loop` ends when an enumerator in it runs out, and so does this one.
  def test_loop_do_ends_when_an_enumerator_in_it_runs_out
    player = played do
      shown = 0
      game_loop do
        shown = 0
        dice = ROLLS.each_with_index
        loop do
          roll, at = dice.next
          break if roll == 99 && at > 0
        end
        shown = 1
      end
    end

    assert_equal 1, player[:shown]
  end

  def test_break_in_begin_end_while_under_a_game_test_is_refused_naming_the_form
    error = assert_raises(Refused) do
      built do
        n = 10
        at = 0
        game_loop do
          at = 0
          begin
            at += 1
            break if at == 3
          end while at < n
        end
      end
    end
    assert_includes error.message, "`begin ... end while`"
  end

  def test_a_break_leaves_only_the_loop_it_is_in
    player = played do
      rows = 3
      row = 0
      cells = 0
      game_loop do
        row = 0
        cells = 0
        while row < rows
          column = 0
          while column < 10
            break if column > row

            cells += 1
            column += 1
          end
          row += 1
        end
      end
    end

    # 1 + 2 + 3 cells, and every row is visited.
    assert_equal [6, 3], [player[:cells], player[:row]]
  end

  def test_a_side_that_breaks_and_one_that_goes_on
    player = played do
      n = 6
      at = 0
      low = 0
      game_loop do
        at = 0
        low = 0
        while at < n
          if at < 3
            low += 1
          else
            break
          end
          at += 1
        end
      end
    end

    assert_equal [3, 3], [player[:low], player[:at]]
  end

  def test_the_boxes_drawn_skip_and_stop_as_ruby_does
    program = built do
      n = 8
      game_loop do
        clear_screen :black
        n.times do |i|
          next if i == 1
          break if i == 4

          draw_rect_at 10 + (i * 20), 10, 8, 8, :blue
        end
      end
    end
    screen = game_player.run(program, frames: 2).screen

    drawn = (0..5).map { |i| screen.pixel(10 + (i * 20), 10) == Color.resolve(:blue) }
    assert_equal [true, false, true, true, false, false], drawn
  end

  def test_break_with_a_value_in_a_loop_the_game_runs_is_refused
    error = assert_raises(Refused) do
      built do
        n = 3
        at = 0
        game_loop do
          while at < n
            break 5 if at == 2

            at += 1
          end
        end
      end
    end
    assert_includes error.message, "value"
  end

  def test_break_under_a_game_test_in_a_loop_ruby_runs_is_refused
    error = assert_raises(Refused) do
      built do
        hp = 3
        seen = 0
        game_loop do
          hp -= 1 if pressed(:a)
          3.times do |k|
            break if hp > k

            seen += 1
          end
        end
      end
    end
    assert_includes error.message, "`break`"
  end
end
