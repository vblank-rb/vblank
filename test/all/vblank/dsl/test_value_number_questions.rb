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

  def test_another_number_question_is_refused_with_the_comparison_to_write
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        lives = var :lives, 3
        game_loop { halt if lives.even? }
      end
    end

    assert_match(/does not answer `even\?`/, error.message)
    assert_match(/lives % 2 == 0/, error.message)
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
