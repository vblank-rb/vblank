# frozen_string_literal: true

require "test_helper"

# A `while` written after its body (`x = y while test`) goes round as often as the block form,
# and as Ruby does. The answer key is Ruby itself, the same lines run on Integers.
class TestPlainRubyTrailingWhile < Minitest::Test
  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    builder.program
  end

  def test_a_trailing_while_changing_the_name_it_tests_goes_round_like_ruby
    player = game_player.run(built do
      start = 3
      count = 0
      total = 0
      game_loop do
        count = start
        total = 0
        total += count while (count += 1) < 10
      end
    end, frames: 2)

    count = 3
    total = 0
    total += count while (count += 1) < 10
    assert_equal [count, total], [player[:count], player[:total]]
  end
end
