# frozen_string_literal: true

require "test_helper"

# What a list answers about all its items, as Ruby's Array does: `sum`, `min`, `max`,
# `include?`, and `each_with_index` to walk them with their places. Each is worked out as the game
# plays, on the items the list holds then.
class TestListAnswers < Minitest::Test
  private def played(frames: 2, &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  # The list holds 3, 9, 4 on the first pass and 3, 9, 4, 1 on the second.
  def test_sum_min_and_max_answer_for_the_items_held_now
    player = played do
      marks = Array.new(3, 0, capacity: 8)
      total = 0
      least = 0
      most = 0
      pass = 0
      game_loop do
        pass += 1
        marks[0] = 3
        marks[1] = 9
        marks[2] = 4
        marks << 1 if pass == 2
        total = marks.sum
        least = marks.min
        most = marks.max
      end
    end

    assert_equal [17, 1, 9], [player[:total], player[:least], player[:most]]
  end

  def test_sum_of_fractions_holds_the_fraction
    player = played(frames: 1) do
      speeds = Array.new(capacity: 4)
      total = 0.0
      game_loop do
        speeds << 0.5
        speeds << 1.25
        total = speeds.sum
      end
    end

    assert_in_delta 1.75, player[:total]
  end

  # Ruby's `min` and `max` of an empty Array are nil, which a game number reads as 0.
  def test_min_and_max_of_an_empty_list_read_as_nought
    player = played(frames: 1) do
      marks = Array.new(capacity: 4)
      least = 5
      most = 5
      game_loop do
        least = marks.min
        most = marks.max
        marks << 2
        marks.pop
      end
    end

    assert_equal [0, 0], [player[:least], player[:most]]
  end

  def test_include_asks_whether_any_item_is_the_number
    player = played(frames: 1) do
      seen = [4, 7, 2]
      has_seven = 0
      has_five = 0
      game_loop do
        seen[0] += 0
        has_seven = 1 if seen.include?(7)
        has_five = 1 if seen.include?(5)
      end
    end

    assert_equal [1, 0], [player[:has_seven], player[:has_five]]
  end

  # Each item and its place: 3 at 0, 9 at 1, 4 at 2 adds up 0 + 9 + 8.
  def test_each_with_index_hands_each_item_and_its_place
    player = played(frames: 1) do
      marks = [3, 9, 4]
      weighted = 0
      game_loop do
        weighted = 0
        marks[0] += 0
        marks.each_with_index { |mark, at| weighted += mark * at }
      end
    end

    assert_equal 17, player[:weighted]
  end
end
