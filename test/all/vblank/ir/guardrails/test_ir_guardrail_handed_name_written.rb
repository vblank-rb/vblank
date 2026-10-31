# frozen_string_literal: true

require "test_helper"
require "stringio"

# A NAME HANDED A GAME VARIABLE AND THEN WRITTEN IN GAME CODE. A name holds a value, as in Ruby, so
# the write moves the name and the variable stays as it was. That is what the language says, and
# almost never what a line like `flag = 0` in a game meant, and the game builds and plays wrong
# with nothing said. So the build says.
class TestIRGuardrailHandedNameWritten < Minitest::Test
  private def build_warnings(&game)
    err = StringIO.new
    VBlank.build("HANDED", console: :gba, out: StringIO.new, err: err, &game)
    err.string
  end

  def test_a_block_argument_written_is_said_naming_the_variable_left_alone
    said = build_warnings do
      shut = [var(:left_door, 1), var(:right_door, 1)]
      game_loop { shut.each { |flag| flag = 0 } }
    end

    assert_match(/`flag`/, said)
    assert_match(/:left_door/, said)
    assert_match(/does not change/, said)
    assert_match(/test_ir_guardrail_handed_name_written\.rb:\d+/, said)
  end

  def test_a_method_argument_written_is_said
    said = build_warnings do
      def hurt(hp) = hp = hp - 1

      lives = var :lives, 3
      shown = var :shown, 0
      game_loop { shown = hurt(lives) }
    end

    assert_match(/`hp`/, said)
    assert_match(/:lives/, said)
  end

  def test_a_local_taken_from_a_hash_and_written_is_said
    said = build_warnings do
      states = { left: var(:left_state, 0) }
      shown = var :shown, 0
      game_loop do
        state = states.fetch(:left)
        state = state + 1
        shown = state
      end
    end

    assert_match(/`state`/, said)
    assert_match(/:left_state/, said)
  end

  def test_a_handed_name_added_to_is_said
    said = build_warnings do
      shifts = [var(:left_shift, 0)]
      shown = var :shown, 0
      game_loop do
        shifts.each do |shift|
          shift += 1
          shown = shift
        end
      end
    end

    assert_match(/`shift`/, said)
    assert_match(/:left_shift/, said)
  end

  def test_a_line_said_once_however_many_times_it_is_recorded
    said = build_warnings do
      shut = [var(:left_door, 1), var(:right_door, 1)]
      game_loop { shut.each { |flag| flag = 0 } }
    end

    assert_equal 1, said.scan("`flag`").length
  end

  def test_a_name_moved_while_setting_up_says_nothing
    said = build_warnings do
      hero_x = var :hero_x, 1
      enemy_x = var :enemy_x, 2
      target = hero_x
      target = enemy_x
      shown = 0
      game_loop { shown = target }
    end

    refute_match(/`target`/, said)
  end

  def test_a_game_variable_written_says_nothing
    said = build_warnings do
      hp = var :hp, 3
      game_loop { hp = hp - 1 }
    end

    refute_match(/`hp`/, said)
  end

  def test_a_copy_of_a_number_changed_says_nothing
    said = build_warnings do
      hp = var :hp, 3
      game_loop do
        left = hp
        left = left - 1
        hp = left
      end
    end

    refute_match(/`left`/, said)
  end
end
