# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../plain_ruby_game_parts"

# A plain `true` or `false` instance variable in game code: a flag the build keeps for itself is
# left alone, and one whose test decides what the game does as it plays, while game code changes
# it, is refused naming `game_variables`. The parts are in test/plain_ruby_game_parts.rb.
class TestPlainRubyFlags < Minitest::Test
  # Steps::Throwaway tries the side of a test Ruby skips in a forked copy of the build, and a
  # process forks only from the main Ractor.
  runs_on_the_main_ractor!

  Refused = VBlank::DSL::PlainRuby::Refused

  private def played(part, *routines, frames: 3)
    builder = Builder.new
    part.new(builder)
    builder.game_loop { routines.each { |routine| builder.call(routine) } }
    builder.finalize_program
    game_player.run(builder.program, frames: frames)
  end

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    builder
  end

  # FLAGS THE BUILD KEEPS FOR ITSELF.

  def test_a_once_guard_read_from_a_second_routine_is_not_refused
    assert_equal 6, played(PlannedTwicePart, :planned_once_tick, :planned_twice_tick)[:planned_once_steps]
  end

  def test_a_flag_switched_on_for_one_call_and_put_back_is_not_refused
    player = played(SwitchedPart, :switched_tick)

    assert_equal [3, 3], [player[:switched_slow], player[:switched_fast]]
  end

  # The side Ruby skips is tried on a copy of the build, so nothing it changes reaches the build:
  # `@label` is still :none, and the game counts every pass.
  def test_a_flag_tested_where_the_skipped_side_changes_a_plain_value_builds_as_without_it
    builder = built do
      @shown = false
      @label = :none
      seen = var :seen, 0
      game_loop do
        @label = :shown if @shown
        seen += 1 if @label == :none
      end
    end

    assert_equal 3, game_player.run(builder.program, frames: 3)[:seen]
  end

  # FLAGS THE GAME KEEPS, NAMED NOWHERE.

  def test_an_unnamed_flag_one_routine_sets_and_another_tests_is_refused
    error = assert_raises(Refused) do
      played(UnnamedDoorOpenedFirstPart, :door_opened_first_open, :door_opened_first_test)
    end

    assert_match(/`@open` is changed while the game plays/, error.message)
    assert_match(/game_variables :open` to UnnamedDoorOpenedFirstPart/, error.message)
    assert_match(/plain_ruby_game_parts\.rb:\d+/, error.message)
  end

  def test_an_unnamed_flag_one_routine_tests_and_another_sets_is_refused
    error = assert_raises(Refused) do
      played(UnnamedDoorTestedFirstPart, :door_tested_first_test, :door_tested_first_open)
    end

    assert_match(/game_variables :open` to UnnamedDoorTestedFirstPart/, error.message)
  end

  def test_an_unnamed_flag_tested_around_game_code_then_set_in_one_routine_is_refused
    error = assert_raises(Refused) { played(UnnamedDoorOneRoutinePart, :door_one_routine_tick) }

    assert_match(/game_variables :open` to UnnamedDoorOneRoutinePart/, error.message)
    assert_match(/plain_ruby_game_parts\.rb:\d+/, error.message)
  end

  def test_an_unnamed_flag_whose_run_side_holds_game_code_and_is_set_in_that_routine_is_refused
    error = assert_raises(Refused) { played(UnnamedDoorOneRoutineRunSidePart, :door_one_routine_run_tick) }

    assert_match(/game_variables :open` to UnnamedDoorOneRoutineRunSidePart/, error.message)
  end

  def test_a_flag_of_the_game_block_one_routine_sets_and_the_loop_tests_is_refused
    error = assert_raises(Refused) do
      built do
        @open = false
        seen = var :seen, 0
        func(:open_door) { @open = true }
        game_loop do
          call :open_door if pressed(:a)
          seen += 1 if @open
        end
      end
    end

    assert_includes error.message, "`game_variables :open` to the game block"
    assert_includes error.message, "`true` or `false`"
    assert_match(/\(at test_plain_ruby_flags\.rb:\d+\)/, error.message)
  end

  def test_a_flag_of_the_game_block_tested_then_set_in_the_loop_is_refused
    error = assert_raises(Refused) do
      built do
        @open = false
        seen = var :seen, 0
        game_loop do
          seen += 1 if @open
          @open = true
        end
      end
    end

    assert_includes error.message, "`game_variables :open` to the game block"
  end

  def test_a_flag_left_nil_one_routine_tests_and_another_sets_is_told_to_start_as_false
    error = assert_raises(Refused) do
      built do
        seen = var :seen, 0
        func(:check_door) { seen += 1 if @open }
        func(:open_door) { @open = true }
        game_loop { call :check_door }
      end
    end

    assert_includes error.message, "give `@open` `false` where it is first set"
  end

  # THE SAME FLAG NAMED: a game variable, held to its twin written with `var`.

  def test_a_named_flag_one_routine_sets_and_another_tests_plays_as_a_var
    named = played(NamedDoorPart, :named_door_test, :named_door_open, frames: 5)[:named_door_seen]

    assert_equal played(DoorWithVarPart, :door_var_test, :door_var_open, frames: 5)[:door_var_seen], named
    assert_equal 3, named
  end
end
