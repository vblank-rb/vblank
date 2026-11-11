# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/game_with_two_parts/first"
VBlank.require_game_file "../../../plain_ruby_game_parts"
VBlank.require_game_file "../../../plain_ruby_loop_parts"

# What files of one game share when each is brought in by `VBlank.require_game_file`.
class TestPlainRubyParts < Minitest::Test
  def test_a_file_keeps_its_own_locals
    assert_equal 1, TWO_PARTS_SPEED
  end

  def test_a_constant_and_a_method_cross_between_files
    assert_equal 18, TWO_PARTS_ACROSS
  end

  private def played(part, *routines)
    builder = Builder.new
    part.new(builder)
    builder.game_loop { routines.each { |routine| builder.call(routine) } }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)
    player
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
  private def counts_each_pass(passes: 3, &count)
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

  def test_a_part_changes_names_unpacked_from_its_builders_var
    player = played(TwoNamesPart, :unpacked_tick)

    assert_equal [4, 4], [player[:unpacked_first], player[:unpacked_second]]
  end
end
