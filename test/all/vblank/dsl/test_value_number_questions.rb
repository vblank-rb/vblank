# frozen_string_literal: true

require "test_helper"

# Ruby's own questions about a number, asked of a game's number as a game writes them:
# `if lives.zero?`. Each answers what the comparison with nought answers, as the game runs.
class TestValueNumberQuestions < Minitest::Test
  # A count that starts below nought and goes up by one a frame, with a flag for each question
  # set on the frames it is true.
  private def counting_game
    builder = Builder.new
    builder.instance_eval do
      count = var :count, -2
      zeros = var :zeros, 0
      ups = var :ups, 0
      downs = var :downs, 0
      game_loop do
        zeros += 1 if count.zero?
        ups += 1 if count.positive?
        downs += 1 if count.negative?
        count += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # Five passes see -2, -1, 0, 1 and 2: two below nought, one at it, two above.
  def test_zero_positive_and_negative_answer_as_ruby_does
    played = game_player.run(counting_game, frames: 5)

    assert_equal 1, played[:zeros], "zero? on the one pass the count is 0"
    assert_equal 2, played[:ups], "positive? on 1 and 2"
    assert_equal 2, played[:downs], "negative? on -2 and -1"
  end

  # A count from -3 to 3, a pass each, with a count for each question on the passes it holds.
  private def parity_game
    builder = Builder.new
    builder.instance_eval do
      count = var :count, -3
      evens = var :evens, 0
      odds = var :odds, 0
      inside = var :inside, 0
      nonzeros = var :nonzeros, 0
      game_loop do
        evens += 1 if count.even?
        odds += 1 if count.odd?
        inside += 1 if count.between?(-1, 2)
        nonzeros += 1 if count.nonzero?
        count += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # Ruby's answers for -3 to 3: even on -2, 0 and 2; odd on -3, -1, 1 and 3; between -1 and 2 on
  # -1, 0, 1 and 2, both ends counted; not zero on all but 0.
  def test_even_odd_between_and_nonzero_answer_as_ruby_does
    numbers = (-3..3).to_a
    played = game_player.run(parity_game, frames: numbers.length)

    assert_equal numbers.count(&:even?), played[:evens]
    assert_equal numbers.count(&:odd?), played[:odds]
    assert_equal numbers.count { |n| n.between?(-1, 2) }, played[:inside]
    assert_equal numbers.count(&:nonzero?), played[:nonzeros]
  end

  # Ruby's Float answers neither.
  def test_even_on_a_fraction_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        speed = var :speed, 1.5
        game_loop { halt if speed.even? }
      end
    end

    assert_match(/holds a fraction/, error.message)
  end

  # Ruby's `nonzero?` hands back the number or nil, and a game's number is never nil.
  def test_nonzero_used_as_a_number_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      game = VBlank::DSL::PlainRuby.rewrite(proc do
        lives = 3
        shown = 0
        game_loop do
          lives -= 1
          shown = lives.nonzero? || 1
        end
      end)
      Builder.new.instance_eval(&game)
    end

    assert_match(/uses `nonzero\?` as a number/, error.message)
  end

  # Given to a name, Ruby's `nonzero?` keeps the number; here it would keep a yes or no.
  def test_nonzero_given_to_a_name_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      game = VBlank::DSL::PlainRuby.rewrite(proc do
        lives = 3
        shown = 0
        game_loop do
          lives -= 1
          shown = lives.nonzero?
        end
      end)
      Builder.new.instance_eval(&game)
    end

    assert_match(/uses `nonzero\?` as a number/, error.message)
  end

  def test_another_number_question_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        lives = var :lives, 3
        game_loop { halt if lives.integer? }
      end
    end

    assert_match(/does not answer `integer\?`/, error.message)
  end

  def test_a_question_no_number_has_is_still_ruby_s_own_error
    assert_raises(NoMethodError) do
      Builder.new.instance_eval do
        lives = var :lives, 3
        game_loop { halt if lives.shiny? }
      end
    end
  end
end
