# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../plain_ruby_game_parts"

# A plain `true` or `false` instance variable in game code: a flag the build keeps for itself is
# left alone; one the source shows game code changes is the game's; and one whose test decides
# what the game does as it plays, changed where the source cannot show it, is refused naming
# `game_variables`. The parts are in test/plain_ruby_game_parts.rb.
class TestPlainRubyFlags < Minitest::Test
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

  # Flags the build keeps for itself.

  def test_a_once_guard_read_from_a_second_routine_is_not_refused
    assert_equal 6, played(PlannedTwicePart, :planned_once_tick, :planned_twice_tick)[:planned_once_steps]
  end

  def test_a_flag_switched_on_for_one_call_and_put_back_is_not_refused
    player = played(SwitchedPart, :switched_tick)

    assert_equal [3, 3], [player[:switched_slow], player[:switched_fast]]
  end

  def test_a_flag_whose_side_only_raises_is_not_refused
    assert_equal 3, played(WrittenOncePart, :written_once_tick)[:written_once_steps]
  end

  # A flag nothing in game code changes is Ruby's to decide, whatever its sides hold.
  def test_a_flag_game_code_never_changes_is_not_refused
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

  # Flags the game keeps, named nowhere: each is given a value in a routine's block, so it is the
  # game's from the first line of game code that tests or sets it, and plays as Ruby would.

  def test_an_unnamed_flag_one_routine_sets_and_another_tests_plays_as_ruby
    player = played(UnnamedDoorOpenedFirstPart, :door_opened_first_open, :door_opened_first_test)

    assert_equal 3, player[:door_opened_first_seen]
  end

  def test_an_unnamed_flag_one_routine_tests_and_another_sets_plays_as_ruby
    player = played(UnnamedDoorTestedFirstPart, :door_tested_first_test, :door_tested_first_open)

    assert_equal 2, player[:door_tested_first_seen]
  end

  def test_an_unnamed_flag_tested_around_game_code_then_set_in_one_routine_plays_as_ruby
    assert_equal 2, played(UnnamedDoorOneRoutinePart, :door_one_routine_tick)[:door_one_routine_seen]
  end

  def test_an_unnamed_flag_whose_run_side_holds_game_code_and_is_set_in_that_routine_plays_as_ruby
    assert_equal 1, played(UnnamedDoorOneRoutineRunSidePart, :door_one_routine_run_tick)[:door_one_routine_run_seen]
  end

  def test_a_flag_of_the_game_block_one_routine_sets_and_the_loop_tests_plays_as_ruby
    builder = built do
      @open = false
      passes = var :passes, 0
      seen = var :seen, 0
      func(:open_door) { @open = true }
      game_loop do
        passes += 1
        call :open_door if passes == 2
        seen += 1 if @open
      end
    end

    assert_equal 2, game_player.run(builder.program, frames: 3)[:seen]
  end

  def test_a_flag_of_the_game_block_tested_then_set_in_the_loop_plays_as_ruby
    builder = built do
      @open = false
      seen = var :seen, 0
      game_loop do
        seen += 1 if @open
        @open = true
      end
    end

    assert_equal 2, game_player.run(builder.program, frames: 3)[:seen]
  end

  # A flag set outright in a method, which the source does not show to be game code, and tested
  # in another routine: the build cannot tell the method is game code until it records it, so it
  # stops and names the fix.
  def test_an_unnamed_flag_set_in_a_method_and_tested_in_another_routine_is_refused
    error = assert_raises(Refused) do
      played(UnnamedLatchPart, :latch_test, :latch_set)
    end

    assert_match(/`@set` is changed while the game plays/, error.message)
    assert_match(/game_variables :set` to UnnamedLatchPart/, error.message)
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

  # The same flag named: a game variable, held to its twin written with `var`.

  def test_a_named_flag_one_routine_sets_and_another_tests_plays_as_a_var
    named = played(NamedDoorPart, :named_door_test, :named_door_open, frames: 5)[:named_door_seen]

    assert_equal played(DoorWithVarPart, :door_var_test, :door_var_open, frames: 5)[:door_var_seen], named
    assert_equal 3, named
  end
end
