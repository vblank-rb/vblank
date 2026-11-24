# frozen_string_literal: true

require "test_helper"

# A loop's count may be kept in an index register where nothing in the loop disturbs it. A body that
# reads a list at a number of its own uses the register for that, so the count must stay in memory,
# and the loop must still go round as many times as Ruby's.
class TestLoopCountBesideIndexRegister < Minitest::Test
  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    builder.program
  end

  def test_a_counted_loop_reading_a_list_at_another_number_goes_round_like_ruby
    player = game_player.run(built do
      words = list :words, capacity: 8, full_of: 3
      at = var :at, 2
      sum = var :sum, 0
      turns = var :turns, 0
      game_loop do
        sum = 0
        turns = 0
        5.times do
          sum += words[at]
          turns += 1
        end
        j = var :j, 0
        j = 0
        while j < 6
          sum += words[at]
          j += 1
        end
      end
    end, frames: 2)

    assert_equal [33, 5], [player[:sum], player[:turns]]
  end
end
