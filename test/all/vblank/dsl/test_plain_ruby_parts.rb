# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/game_with_two_parts/first"
VBlank.require_game_file "../../../plain_ruby_game_parts"
VBlank.require_game_file "../../../plain_ruby_loop_parts"
VBlank.require_game_file "../../../plain_ruby_named_parts"

# What files of one game share when each is brought in by `VBlank.require_game_file`.
class TestPlainRubyParts < Minitest::Test
  def test_a_file_keeps_its_own_locals
    assert_equal 1, TWO_PARTS_SPEED
  end

  def test_a_constant_and_a_method_cross_between_files
    assert_equal 18, TWO_PARTS_ACROSS
  end

  private def played(part, *routines, frames: 3)
    builder = Builder.new
    part.new(builder)
    builder.game_loop { routines.each { |routine| builder.call(routine) } }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  # GAME VARIABLES A PART NAMES. Each part keeping its state in instance variables it names with
  # `game_variables` (test/plain_ruby_game_parts.rb) has a twin keeping the same state in `var`,
  # which is the answer key: both played the same, and the number the twin leaves is given too.

  def test_a_named_instance_variable_tested_above_its_change_asks_the_pass_before
    named = played(TiltPart, :tilt_handle, frames: 6)[:tilt_acted]

    assert_equal played(TiltWithVarPart, :tilt_var_handle, frames: 6)[:tilt_var_acted], named
    assert_equal 2, named
  end

  def test_named_instance_variables_shifted_and_summed_in_a_routine_draw_as_the_game_plays
    named = (1..4).map { |frames| played(SeedPart, :seed_draw, frames: frames)[:seed_drawn] }
    with_var = (1..4).map { |frames| played(SeedWithVarPart, :seed_var_draw, frames: frames)[:seed_var_drawn] }

    assert_equal with_var, named
    assert_equal 4, named.uniq.length, "a new number on every pass"
  end

  def test_two_of_one_part_each_keep_their_own_named_instance_variable
    builder = Builder.new
    TickerPart.new(builder, :first_ticker)
    TickerPart.new(builder, :second_ticker)
    builder.game_loop do
      builder.call(:first_ticker)
      builder.call(:first_ticker)
      builder.call(:second_ticker)
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [4, 2], [player[:ticker_part_ticks], player[:ticker_part_ticks_2]]
  end

  # FastTiltPart reads its parent's `@busy`, named by the parent, and changes `@nudges`, named by itself.
  def test_a_subclass_follows_what_its_parent_names_and_what_it_names
    player = played(FastTiltPart, :tilt_handle, :fast_tilt_nudge, frames: 6)

    assert_equal [2, 2], [player[:tilt_acted], player[:fast_tilt_nudged]]
  end

  # Flipped on passes 1, 3 and 5, and brighter by one each time it goes on.
  def test_another_part_reads_and_writes_named_instance_variables_through_attributes
    builder = Builder.new
    LampSwitchPart.new(builder, LampPart.new)
    builder.game_loop { builder.call(:lamp_flip) }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 5)

    assert_equal [3, 5], [player[:lamp_ons], player[:lamp_glow]]
  end

  def test_an_unnamed_instance_variable_game_code_tests_then_changes_is_refused_at_the_change
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { played(UnnamedTiltPart, :unnamed_tilt_handle) }

    assert_match(/`@busy` is changed while the game plays.*\(changed at plain_ruby_game_parts\.rb:\d+\)/m, error.message)
    assert_match(/game_variables :busy` to UnnamedTiltPart/, error.message)
  end

  def test_an_unnamed_instance_variable_game_code_counts_then_tests_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { played(UnnamedCountPart, :unnamed_count_tick) }

    assert_match(/`@frames` is changed while the game plays/, error.message)
    assert_match(/game_variables :frames` to UnnamedCountPart/, error.message)
  end

  def test_an_unnamed_instance_variable_one_routine_sets_and_another_tests_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(UnnamedAcrossRoutinesPart, :across_routines_test, :across_routines_set)
    end

    assert_match(/game_variables :mode` to UnnamedAcrossRoutinesPart/, error.message)
  end

  def test_a_module_names_its_own_instance_variable_for_the_class_taking_it_in
    assert_equal 3, played(HolderPart, :holder_hold)[:holder_held]
  end

  def test_a_true_or_false_flag_only_the_build_reads_is_not_refused
    assert_equal 3, played(PlannedOncePart, :planned_once_tick)[:planned_once_steps]
  end

  def test_a_number_set_in_initialize_while_game_code_records_and_read_in_another_routine_is_not_refused
    assert_equal 6, played(ScrollPart, :scroll_part_make, :scroll_part_tick)[:scroll_part_shown]
  end

  # A NAMED VALUE IS THE GAME'S FROM ITS FIRST NUMBER ON (test/plain_ruby_named_parts.rb), each
  # held to its twin written with `var`.

  def test_a_named_value_read_in_a_block_another_part_calls_and_set_back_elsewhere_plays_as_a_var
    named = played(StartingTitlePart, :starting_title_tick, frames: 8)[:starting_title_ended]

    assert_equal played(StartingTitleWithVarPart, :var_starting_title_tick, frames: 8)[:var_starting_title_ended], named
    assert_equal 2, named
  end

  private def cursor_menu(prefix, cursor)
    builder = Builder.new
    CursorMenuPart.new(builder, prefix, cursor.call(builder))
    builder.game_loop { builder.call(:"#{prefix}_tick") }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)
    [player[:"#{prefix}_ball_seen"], player[:"#{prefix}_others"]]
  end

  def test_a_named_value_read_through_attr_reader_and_handed_to_another_part_plays_as_a_var
    named = cursor_menu(:named_cursor, ->(_builder) { NamedCursor.new })

    assert_equal cursor_menu(:var_cursor, ->(builder) { VarCursor.new(builder) }), named
    assert_equal [2, 1], named
  end

  def test_named_values_changed_in_a_method_setting_up_also_calls_play_as_vars
    named = played(BlinkPart, :blink_tick)[:blink_shown]

    assert_equal played(BlinkWithVarPart, :var_blink_tick)[:var_blink_shown], named
    assert_equal 2, named
  end

  def test_a_named_phase_changed_only_by_a_helper_is_read_as_the_game_plays
    named = (1..6).map do |frames|
      player = played(PhasedFadePart, :phased_fade_tick, frames: frames)
      [player[:phased_fade_frames], player[:phased_fade_fading]]
    end
    with_var = (1..6).map do |frames|
      player = played(PhasedFadeWithVarPart, :var_phased_fade_tick, frames: frames)
      [player[:var_phased_fade_frames], player[:var_phased_fade_fading]]
    end

    assert_equal with_var, named
    assert_equal [4, 4], with_var.last
  end

  # Frames and passes of fading after six passes of a screen made inside a routine.
  private def screen_in_play(screen_class, prefix, made_in_play:)
    builder = Builder.new
    ScreenInPlayPart.new(builder, screen_class, prefix, made_in_play: made_in_play)
    builder.game_loop { builder.call(:"#{prefix}_tick") }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 6)
    [player[:"#{prefix}_frames"], player[:"#{prefix}_fading"]]
  end

  def test_a_named_phase_set_in_initialize_of_a_screen_made_in_a_routine_starts_it_once
    [HelperScreen, EndlessHelperScreen, WriterScreen, DirectedScreen].each do |screen_class|
      prefix = screen_class.name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      assert_equal [4, 4], screen_in_play(screen_class, :"set_up_#{prefix}", made_in_play: false), "#{screen_class} set up"
      assert_equal [4, 4], screen_in_play(screen_class, prefix, made_in_play: true), "#{screen_class} made in play"
    end
  end

  def test_a_named_hash_of_numbers_plays_as_a_var_for_each_key
    named = played(TiltCountersPart, :tilt_counters_tick, frames: 4)
    with_var = played(TiltCountersWithVarPart, :var_tilt_counters_tick, frames: 4)

    counts = [named[:tilt_counters_part_tilt_counters_left], named[:tilt_counters_part_tilt_counters_right],
              named[:tilt_counters_over]]

    assert_equal %i[var_tilt_counters_left var_tilt_counters_right var_tilt_counters_over].map { |name| with_var[name] }, counts
    assert_equal [4, 3, 3], counts
  end

  # Rotated on passes 1, 3, 4 and 6: [2, 3, 1], the same, [3, 1, 2], [1, 2, 3], all set to 1, the
  # same, holding 1, 1, 2, 3, 1, 1.
  ROTATIONS = {
    RotatingWithVarPart => [:var_rotating_tick, %i[var_rotating_0 var_rotating_1 var_rotating_2 var_rotating_held]],
    RotatingHashPart => [:rotating_hash_tick, %i[rotating_hash_part_states_0 rotating_hash_part_states_1
                                                 rotating_hash_part_states_2 rotating_hash_part_held]],
    RotatingArrayPart => [:rotating_array_tick, %i[rotating_array_part_states_0 rotating_array_part_states_1
                                                   rotating_array_part_states_2 rotating_array_part_held]],
    RotatingVarStatesPart => [:var_states_rotating_tick, %i[var_states_rotating_0 var_states_rotating_1
                                                            var_states_rotating_2 rotating_var_states_part_held]]
  }.freeze

  def test_states_rotated_through_a_held_named_value_play_as_vars
    rotated = ROTATIONS.to_h do |part, (routine, names)|
      states = (1..6).map do |frames|
        player = played(part, routine, frames: frames)
        names.map { |name| player[name] }
      end
      [part, states]
    end

    assert_equal [[2, 3, 1, 1], [2, 3, 1, 1], [3, 1, 2, 2], [1, 2, 3, 3], [1, 1, 1, 1], [1, 1, 1, 1]],
                 rotated[RotatingWithVarPart]
    rotated.each { |part, states| assert_equal rotated[RotatingWithVarPart], states, part.name }
  end

  def test_states_rotated_through_a_held_value_nobody_names_play_as_vars
    states = (1..6).map do |frames|
      player = played(RotatingUnnamedHeldPart, :unnamed_held_rotating_tick, frames: frames)
      (0..2).map { |light| player[:"rotating_unnamed_held_part_states_#{light}"] }
    end

    assert_equal [[2, 3, 1], [2, 3, 1], [3, 1, 2], [1, 2, 3], [1, 1, 1], [1, 1, 1]], states
  end

  def test_a_named_value_given_another_variable_while_setting_up_copies_its_number
    player = played(CopiedLevelPart, :copied_level_tick)

    assert_equal [8, 5], [player[:copied_level_part_level], player[:copied_level_source]]
  end

  def test_an_unnamed_value_sharing_a_variable_given_another_is_refused_naming_game_variables
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { played(HandedHeldPart, :handed_held_tick) }

    assert_match(/belongs to something else.*add `game_variables :held` to HandedHeldPart/, error.message)
  end

  def test_named_values_swapped_in_one_line_change_places_on_every_pass
    totals = (1..3).map { |frames| played(SwappingPart, :swapping_tick, frames: frames)[:swapping_part_total] }

    assert_equal [12, 21, 12], totals
  end

  def test_named_values_given_names_of_the_games_own_are_read_by_those_names
    player = played(OwnNamedLightsPart, :own_named_lights_tick, frames: 1)

    assert_equal [2, 1, 1], [player[:lit_state_0], player[:lit_state_1], player[:lit_held]]
  end

  # Only the second of one part swaps.
  def test_a_second_object_of_a_part_with_names_of_its_own_takes_the_next_free_names
    builder = Builder.new
    OwnNamedLightsPart.new(builder, :first_lights_tick)
    OwnNamedLightsPart.new(builder, :second_lights_tick)
    builder.game_loop { builder.call(:second_lights_tick) }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 1)

    assert_equal [1, 2, 0, 1], %i[lit_state_0 lit_state_0_2 lit_held lit_held_2].map { |name| player[name] }
  end

  def test_a_name_of_the_games_own_that_another_variable_has_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      builder = Builder.new
      builder.var(:lit_held, 0)
      OwnNamedLightsPart.new(builder)
    end

    assert_match(/variable name :lit_held, and another variable of the game has that name/, error.message)
  end

  def test_a_named_array_of_numbers_at_an_index_the_game_works_out_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { played(CountsByNumberPart, :counts_by_number_tick) }

    assert_match(/worked out as the game plays/, error.message)
  end

  def test_a_named_struct_field_changed_under_a_test_plays_as_a_var
    named = (1..4).map { |frames| played(BoxCountPart, :box_count_tick, frames: frames)[:box_count_seen] }
    with_var = (1..4).map { |frames| played(BoxCountWithVarPart, :box_var_count_tick, frames: frames)[:box_var_count_seen] }

    assert_equal with_var, named
    assert_equal [2, 4, 6, 6], named
  end

  # Moving from the second pass on, so two of three passes see it moving.
  def test_a_struct_subclass_naming_its_field_keeps_a_game_state
    assert_equal 2, played(ModeBoxPart, :mode_box_tick)[:mode_box_turns]
  end

  def test_attributes_made_from_a_list_of_names_reach_the_named_instance_variable
    assert_equal 3, played(ListedGaugePart, :listed_gauge_tick)[:listed_gauge_seen]
  end

  def test_a_class_reopened_to_name_more_follows_every_name
    assert_equal 9, played(ReopenedCounter, :reopened_counter_tick)[:reopened_counter_seen]
  end

  def test_game_variables_in_a_method_of_a_module_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { NamedInMethod.name_them }

    assert_match(/`game_variables`.*body/, error.message)
  end

  # BUILD-TIME RUBY STAYS RUBY'S. Planned: 2 loads that do not fit, 12 by each, 6 by to_h, 6 by
  # times, 15 + 3 filled in, 2 by a lambda, 2 in a Struct, 6 of its own, 15 in the buffer; written
  # to the list on every pass.
  def test_build_time_ruby_in_a_part_made_inside_a_routine_stays_ruby
    builder = Builder.new
    PlanInPlayPart.new(builder, :plan_in_play)
    builder.game_loop { builder.call(:plan_in_play_tick) }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [2, 12, 6, 6, 18, 2, 2, 6, 15], player.list(:plan_in_play_answers)
  end

  def test_a_buffer_a_plan_fills_from_a_routine_stays_ruby
    assert_equal 15, played(BufferedPlanPart, :buffered_plan_tick)[:buffered_plan_total]
  end

  def test_a_named_instance_variable_read_while_it_holds_nil_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) { played(UnsetNamedPart, :unset_named_tick) }

    assert_match(/`@aim` is a game variable, and it holds `nil`/, error.message)
  end

  # A count three a setting-up method works out, counted by `repeat` and by `times` on every pass,
  # and a count of two game code gives outright before it counts by it.
  def test_instance_variables_changed_while_building_or_never_read_back_play_as_ruby
    player = played(BuildTimeCountsPart, :build_counts_tick)

    assert_equal [18, 6], [player[:build_counts_hits], player[:build_counts_rows]]
  end

  def test_a_part_changes_a_name_made_by_its_builders_var
    assert_equal 3, played(CounterPart, :counter_tick)[:counter_count]
  end

  def test_a_part_fills_in_a_name_started_as_nil
    assert_equal 7, played(SparklePart, :sparkle_make)[:sparkle_glint]
  end

  def test_a_part_changes_a_plain_number_with_no_var_of_its_own
    assert_equal 6, played(TallyPart, :tally_tick, :tally_show)[:tally_seen]
  end

  def test_two_of_one_part_each_keep_their_own_number
    builder = Builder.new
    SeveralOfOnePart.new(builder, :first_tick)
    SeveralOfOnePart.new(builder, :second_tick)
    builder.game_loop do
      builder.call(:first_tick)
      builder.call(:first_tick)
      builder.call(:second_tick)
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [4, 2], [player[:ticks], player[:ticks_2]]
  end

  # A METHOD CALLED ON EVERY PASS SETS ITS NAMES ON EVERY PASS. Each of LoopCountPart's methods
  # (test/plain_ruby_loop_parts.rb) starts a count at 0 and counts in a block or a loop. The game
  # keeps the answer of each pass, so a count that carried on from the pass before shows as a
  # bigger number on a later one. +count+ is handed the part and three, a number the game keeps.
  # +holding+ is a button held from the start.
  private def counts_each_pass(passes: 3, holding: nil, &count)
    builder = Builder.new
    part = LoopCountPart.new(builder)
    three = builder.var(:three, 3)
    answers = builder.list(:answers, capacity: passes * 4, full_of: -1)
    pass = builder.var(:pass, 0)
    builder.game_loop do
      answers[pass] = builder.instance_exec(part, three, &count)
      pass.increase!(1)
    end
    builder.finalize_program
    player = game_player
    player.hold(holding) if holding
    player.run(builder.program, frames: passes + 1)
    player.list(:answers).first(passes)
  end

  def test_a_count_started_in_a_parts_method_starts_afresh_on_every_pass
    assert_equal [3, 3, 3], counts_each_pass { |part, three| part.counted_by_repeat(three) }, "@build.repeat"
    assert_equal [3, 3, 3], counts_each_pass { |part, three| part.counted_by_repeat_on_local(three) }, "build.repeat"
    assert_equal [3, 3, 3], counts_each_pass { |part, three| part.counted_over_ruby_list(three) }, "a Ruby list"
    assert_equal [3, 3, 3], counts_each_pass { |part, three| part.counted_over_named_ruby_list(three) }, "a Ruby list in a name"
    assert_equal [3, 3, 3], counts_each_pass { |part, three| part.counted_in_one_of_two_names(three) }, "count, other = 0, 0"
  end

  # Every block verb called on a builder a part holds means what it means called bare.
  def test_a_beat_counted_in_a_parts_method_counts_as_the_bare_verb_does
    bare = counts_each_pass(passes: 4) { |_part, _three| loop_count_by_bare_every }

    assert_equal bare, counts_each_pass(passes: 4) { |part, _three| part.counted_by_every }
    assert_equal [0, 1], bare.uniq.sort, "one on a pass the beat falls on, none on the others"
  end

  # The count a job started by the block has reached after a few passes.
  private def steps_after_passes
    builder = Builder.new
    taken = builder.var(:taken, 0)
    steps = yield(LoopCountPart.new(builder), builder)
    builder.game_loop { taken.store!(steps) }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 4)
    player[:taken]
  end

  def test_a_job_started_in_a_parts_method_steps_as_the_bare_verb_does
    bare = steps_after_passes { |_part, build| build.instance_exec { loop_steps_each_pass_bare(:bare_job) } }

    assert_equal bare, steps_after_passes { |part, _build| part.steps_each_pass(:part_job) }
    assert_operator bare, :>, 1
  end

  def test_a_count_by_after_in_a_parts_method_counts_as_the_bare_verb_does
    bare = counts_each_pass(passes: 4) { |_part, _three| loop_count_by_bare_after }

    assert_equal bare, counts_each_pass(passes: 4) { |part, _three| part.counted_by_after }
    assert_equal [0, 1], bare.uniq.sort, "one on the pass it runs, none on the others"
  end

  def test_a_menu_row_picked_in_a_parts_method_counts_as_the_bare_verb_does
    bare = counts_each_pass(holding: :a) { |_part, _three| loop_picks_by_bare_menu(:bare_menu) }

    assert_equal bare, counts_each_pass(holding: :a) { |part, _three| part.picks_by_menu(:part_menu) }
    assert_equal [0, 1], bare.uniq.sort, "one on the pass the press picks the row, none on the others"
  end

  def test_a_step_once_a_frame_in_a_parts_method_steps_as_the_bare_verb_does
    bare = steps_after_passes { |_part, build| build.instance_exec { loop_steps_once_a_frame_bare } }

    assert_equal bare, steps_after_passes { |part, _build| part.steps_once_a_frame }
    assert_operator bare, :>, 1
  end

  def test_a_step_on_a_timers_tick_in_a_parts_method_steps_as_the_bare_verb_does
    bare = steps_after_passes { |_part, build| build.instance_exec { loop_steps_on_tick_bare(:bare_timer) } }

    assert_equal bare, steps_after_passes { |part, _build| part.steps_on_tick(:part_timer) }
    assert_operator bare, :>, 1
  end

  def test_a_count_started_in_a_game_files_method_starts_afresh_on_every_pass
    assert_equal [3, 3, 3], counts_each_pass { |_part, three| loop_count_by_bare_repeat(three) }, "repeat"
    assert_equal [3, 3, 3], counts_each_pass { |_part, three| loop_count_by_repeat_on(self, three) }, "build.repeat"
  end

  def test_a_count_in_loops_of_a_parts_method_starts_afresh_on_every_pass
    assert_equal [9, 9, 9], counts_each_pass { |part, three| part.counted_by_while_in_while(three) }, "while in while"
    assert_equal [6, 6, 6], counts_each_pass { |part, three| part.counted_by_ruby_loop_in_while(three) }, "Ruby's loop in until"
  end

  # Rows 0, 1 and 2 count 0, 1 and 2, so one row counts two: a count kept from the row before would
  # count 0, 1 and 3.
  def test_a_count_set_at_the_top_of_a_loop_starts_afresh_on_every_round
    assert_equal [1, 1, 1], counts_each_pass { |part, three| part.rounds_with_two_counted(three) }
  end

  # The same method called twice while setting up: the second call's first line sets the name again.
  def test_a_method_called_twice_while_setting_up_starts_its_count_twice
    builder = Builder.new
    builder.instance_eval do
      first = var(:first, 0)
      second = var(:second, 0)
      first.store!(loop_count_by_bare_repeat(3))
      second.store!(loop_count_by_bare_repeat(3))
      game_loop { wait_vblank }
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [3, 3], [player[:first], player[:second]]
  end

  # Plays +block+, rewritten as a game's block is, and hands back the player.
  private def played_game(frames: 4, &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  # The answer key is the same lines written in the game loop: nil, read as a number, is 0.
  def test_a_name_set_to_nil_in_a_method_called_every_pass_reads_as_0_on_every_pass
    in_method = played_game do
      numbered = var(:numbered, 3)
      answers = list(:answers, capacity: 8, full_of: -1)
      pass = var(:pass, 0)
      game_loop do
        nil_read_before_numbered(numbered, answers, pass)
        pass += 1
      end
    end
    in_block = played_game do
      numbered = var(:numbered, 3)
      answers = list(:answers, capacity: 8, full_of: -1)
      pass = var(:pass, 0)
      game_loop do
        held = nil
        answers[pass] = held
        repeat(1) { held = numbered }
        pass += 1
      end
    end

    assert_equal [0, 0, 0], in_block.list(:answers).first(3), "written in the game loop"
    assert_equal [0, 0, 0], in_method.list(:answers).first(3), "in a method"
  end

  # The method's first line runs twice while setting up, starting its total at 2 and then at 12.
  def test_a_method_whose_first_line_starts_differently_on_each_call_starts_each_call_afresh
    in_method = played_game(frames: 2) do
      first = var(:first, 0)
      second = var(:second, 0)
      first.store!(total_from_double(1))
      second.store!(total_from_double(6))
      game_loop { wait_vblank }
    end
    in_block = played_game(frames: 2) do
      first = var(:first, 0)
      second = var(:second, 0)
      total = 1 * 2
      repeat(2) { total += 1 }
      first.store!(total)
      total = 6 * 2
      repeat(2) { total += 1 }
      second.store!(total)
      game_loop { wait_vblank }
    end

    assert_equal [4, 14], [in_block[:first], in_block[:second]], "written in the game's block"
    assert_equal [4, 14], [in_method[:first], in_method[:second]], "in a method"
  end

  # Two files each have a local `steps_taken`. As in Ruby, each is its own: the other file's
  # method, called between this one's count and its read, leaves this one's as it was.
  def test_a_local_of_one_file_keeps_its_own_variable_beside_another_files_of_the_same_name
    player = played_game(frames: 2) do
      counted = var(:counted, 0)
      counted.store!(steps_taken_beside_other_files(3))
      game_loop { counted.store!(steps_taken_beside_other_files(5)) }
    end

    assert_equal 5, player[:counted]
  end

  # The game's own local of that name, counted before a wait and read after it, with the other
  # file's method counting in its own in between.
  def test_a_local_kept_across_a_wait_is_not_changed_by_another_files_local_of_the_same_name
    player = played_game(frames: 6) do
      counted = var(:counted, 0)
      game_loop do
        steps_taken = 0
        repeat(3) { steps_taken += 1 }
        wait_vblank
        steps_taken_by_bare_repeat(2)
        counted.store!(steps_taken)
      end
    end

    assert_equal 3, player[:counted]
  end

  # On the first pass the second round reads the copy the first round changed; the caller's
  # total stays 10 throughout.
  def test_an_argument_changed_in_a_ruby_loop_is_the_methods_own_copy
    player = played_game(frames: 1) do
      total = var(:total, 10)
      seen = var(:seen, 0)
      after = var(:after, 0)
      pass = var(:pass, 0)
      game_loop do
        after.store!(argument_counted_in_ruby_loop(total, pass, seen))
        pass += 1
      end
    end

    assert_equal [10, 11, 11], [player[:total], player[:seen], player[:after]]
  end

  def test_a_part_changes_names_unpacked_from_its_builders_var
    player = played(TwoNamesPart, :unpacked_tick)

    assert_equal [4, 4], [player[:unpacked_first], player[:unpacked_second]]
  end
end
