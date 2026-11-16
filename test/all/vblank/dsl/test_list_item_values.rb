# frozen_string_literal: true

require "test_helper"

# What a list's item can be given. A slot keeps a number, so a value with no number in it
# (nil, a test's true or false) stops the build at the game's line, saying how to write the
# number instead. A test that picks a number (`test ? 1 : 0`) is a number, and is kept.
class TestListItemValues < Minitest::Test
  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder
  end

  private def played(frames:, &block)
    game_player.run(built(&block).program, frames: frames)
  end

  private def assert_refused(*phrases, &block)
    error = assert_raises(ArgumentError) { built(&block) }
    phrases.each { |phrase| assert_includes error.message, phrase }
    assert_match(/test_list_item_values\.rb:\d+/, error.message)
  end

  def test_a_plain_nil_into_a_slot_is_refused_at_the_line
    assert_refused("nil", "`list :answers`", "a number") do
      answers = list :answers, capacity: 4, full_of: 5
      t = nil
      game_loop { answers[1] = t }
    end
  end

  def test_a_plain_nil_pushed_is_refused_at_the_line
    assert_refused("nil", "`list :answers`") do
      answers = list :answers, capacity: 4
      game_loop { answers.push nil }
    end
  end

  def test_a_tests_answer_into_a_slot_is_refused_naming_the_pick_that_works
    assert_refused("true or false", "? 1 : 0") do
      answers = list :answers, capacity: 4, full_of: 0
      pass = var :pass, 0
      game_loop do
        answers[1] = pass == 1
        pass += 1
      end
    end
  end

  def test_true_or_false_into_a_slot_is_refused
    assert_refused("true or false") do
      answers = list :answers, capacity: 4, full_of: 0
      game_loop { answers[0] = true }
    end
  end

  def test_a_tests_answer_filling_a_list_is_refused
    assert_refused("true or false") do
      answers = list :answers, capacity: 4, full_of: 0
      pass = var :pass, 0
      game_loop do
        answers.fill(pass > 2)
        pass += 1
      end
    end
  end

  # The answer key is the same game written with an `if` and a variable.
  def test_a_ternary_on_a_game_test_picks_the_number_a_slot_keeps
    run = played(frames: 5) do
      answers = list :answers, capacity: 4, full_of: 9
      pass = 0
      game_loop do
        answers[pass] = pass == 1 ? 1 : 0 if pass < 4
        pass += 1
      end
    end

    assert_equal [0, 1, 0, 0], run.list(:answers)
  end

  def test_a_ternary_on_a_nil_test_picks_the_number_a_slot_keeps
    run = played(frames: 4) do
      answers = list :answers, capacity: 4, full_of: 9
      t = nil
      pass = 0
      game_loop do
        answers[pass] = t.nil? ? 1 : 0 if pass < 4
        t = 3 if pass == 1
        pass += 1
      end
    end

    assert_equal [1, 1, 0, 0], run.list(:answers)
  end

  def test_an_if_with_an_else_picks_the_number_a_slot_keeps
    run = played(frames: 3) do
      answers = list :answers, capacity: 2, full_of: 9
      pass = 0
      game_loop do
        answers[0] = if pass == 0 then 4 else 6 end
        answers[1] = (pass.zero? ? 7 : 8)
        pass += 1
      end
    end

    assert_equal [6, 8], run.list(:answers)
  end

  Holder = Struct.new(:x)

  def test_a_ternary_into_a_field_picks_the_number_too
    run = played(frames: 3) do
      holder = Holder.new(var(:held_x, 9))
      pass = 0
      game_loop do
        holder.x = pass == 1 ? 3 : 4
        pass += 1
      end
    end

    assert_equal 4, run[:held_x]
  end

  def test_a_pick_with_no_else_into_a_slot_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built do
        answers = list :answers, capacity: 2, full_of: 9
        pass = 0
        game_loop do
          answers[0] = (4 if pass == 0)
          pass += 1
        end
      end
    end
    assert_includes error.message, "else"
  end
end
