# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../plain_ruby_helper_part"

# A game block written in normal Ruby, the way an author sees it: each test plays a tiny game
# and reads the variables it leaves, on every lowering. What a line is rewritten into is
# test_plain_ruby_rewrite.rb's business, and what is refused test_plain_ruby_refusals.rb's.
class TestPlainRuby < Minitest::Test
  # Plays the block, rewritten, for +frames+ frames and hands back the player.
  private def played(frames: 3, allow: [], &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, allow: allow))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  def test_if_runs_only_the_branch_whose_test_holds_as_the_game_plays
    player = played do
      hp = 0
      yes = 0
      no = 0
      game_loop do
        if hp == 0
          yes += 1
        else
          no += 1
        end
        hp += 1
      end
    end

    assert_equal 1, player[:yes]
    assert_operator player[:no], :>=, 1
  end

  def test_if_with_no_else_and_elsif_pick_one_side
    player = played(frames: 6) do
      n = 0
      a = 0
      b = 0
      c = 0
      d = 0
      game_loop do
        d += 1 if n == 0
        if n == 1
          a += 1
        elsif n == 2
          b += 1
        else
          c += 1
        end
        n += 1
      end
    end

    assert_equal [1, 1, 1], [player[:d], player[:a], player[:b]]
    assert_operator player[:c], :>=, 2
  end

  def test_a_ternary_used_as_a_statement_branches_too
    player = played(frames: 2) do
      n = 0
      a = 0
      b = 0
      game_loop do
        n == 0 ? a = 7 : b = 9
        n += 1
      end
    end

    assert_equal [7, 9], [player[:a], player[:b]]
  end

  def test_unless_and_trailing_unless_run_when_the_test_fails
    player = played(frames: 2) do
      n = 1
      a = 0
      b = 0
      game_loop do
        a = 5 unless n == 0
        unless n == 1
          b = 6
        else
          b = 7
        end
        n = 1
      end
    end

    assert_equal [5, 7], [player[:a], player[:b]]
  end

  def test_true_and_false_are_a_yes_or_no_the_game_keeps
    player = played(frames: 3) do
      alive = true
      hit = false
      drawn = 0
      skipped = 0
      game_loop do
        if alive
          drawn += 1
        else
          skipped += 1
        end
        alive = false if hit
        hit = true
      end
    end

    assert_operator player[:drawn], :>=, 1
    assert_operator player[:skipped], :>=, 1
  end

  def test_not_and_unless_and_joined_tests_read_a_yes_or_no
    player = played(frames: 1) do
      open = false
      lit = true
      a = 0
      b = 0
      c = 0
      game_loop do
        a = 1 unless open
        b = 1 if !open && lit
        c = 1 if open || lit
        open = false
      end
    end

    assert_equal [1, 1, 1], [player[:a], player[:b], player[:c]]
  end

  def test_a_yes_or_no_can_take_the_answer_of_a_test
    player = played(frames: 2) do
      hp = 3
      low = false
      seen = 0
      game_loop do
        low = hp < 5
        seen = 1 if low
        hp += 0
      end
    end

    assert_equal 1, player[:seen]
  end

  def test_a_picked_yes_or_no_is_a_yes_or_no
    player = played(frames: 2) do
      hp = 3
      seen = 0
      game_loop do
        low = hp < 5 ? true : false
        seen = 1 if low
        hp += 0
      end
    end

    assert_equal 1, player[:seen]
  end

  def test_a_copy_of_a_yes_or_no_is_a_yes_or_no
    player = played(frames: 2) do
      lit = true
      seen = 0
      game_loop do
        old = lit
        lit = false
        seen = 1 if old
        lit = true
      end
    end

    assert_equal 1, player[:seen]
  end

  # Truthiness is Ruby's: nil and false are falsy, and everything else is truthy. A number is
  # truthy whatever it holds, here as anywhere.
  def test_a_number_is_truthy_even_at_zero
    player = played(frames: 2) do
      hp = 0
      flags = 0
      plain = 0
      seen = 0
      worked_out = 0
      plain_seen = 0
      game_loop do
        seen = 1 if hp
        worked_out = 1 if flags & 4
        plain_seen = 1 if plain
        hp += 0
        flags += 0
      end
    end

    assert_equal [1, 1, 1], [player[:seen], player[:worked_out], player[:plain_seen]]
  end

  def test_nil_and_false_are_falsy_and_a_string_is_truthy
    player = played(frames: 2) do
      nothing = nil
      no = false
      words = "HI"
      a = 0
      b = 0
      c = 0
      game_loop do
        a = 1 if nothing
        b = 1 if no
        c = 1 if words
      end
    end

    assert_equal [0, 0, 1], [player[:a], player[:b], player[:c]]
  end

  def test_or_keeps_a_number_as_ruby_does
    player = played(frames: 2) do
      hp = 5
      kept = 0
      game_loop do
        kept = hp || 9
        hp += 0
      end
    end

    assert_equal 5, player[:kept]
  end

  # Nothing passed, true and false are three answers, and it takes `nil?` to tell the first from
  # the last, as in any Ruby.
  def test_nil_and_a_yes_or_no_are_three_answers
    player = played(frames: 2) do
      def mark(tally, tested = nil)
        if tested.nil?
          tally[:left_out] += 1
        elsif tested
          tally[:yes] += 1
        else
          tally[:no] += 1
        end
      end
      tally = { left_out: var(:left_out, 0), yes: var(:yes, 0), no: var(:no, 0) }
      on = true
      off = false
      game_loop do
        mark(tally)
        mark(tally, on)
        mark(tally, off)
        on = true
        off = false
      end
    end

    assert_equal player[:left_out], player[:yes]
    assert_equal player[:left_out], player[:no]
  end

  PLAYING = 2
  OVER = 3
  WIDE = 40
  TITLE_WORDS = "HI"

  def test_a_name_started_from_a_constant_is_a_variable
    player = played(frames: 2) do
      state = PLAYING
      game_loop { state = OVER }
    end

    assert_equal OVER, player[:state]
  end

  def test_a_name_started_from_a_sum_of_constants_is_a_variable
    player = played(frames: 2) do
      x = WIDE / 2
      seen = 0
      game_loop do
        seen = x
        x += 1
      end
    end

    assert_operator player[:seen], :>=, 20
  end

  def test_a_name_started_from_a_constant_that_is_no_number_stays_plain_ruby
    player = played(frames: 2) do
      words = TITLE_WORDS
      seen = 0
      game_loop do
        seen = 1 if words == "HI"
        words = TITLE_WORDS
      end
    end

    assert_equal 1, player[:seen]
  end

  # `recording or next` must leave the loop's own block, not one the rewrite made.
  def test_or_next_skips_the_rest_of_a_plain_ruby_block
    player = played(frames: 1) do
      count = 0
      [1, nil, 3].each do |each_number|
        kept = each_number or next
        count += kept
      end
      total = var :total, count
      game_loop { total += 0 }
    end

    assert_equal 4, player[:total]
  end

  def test_or_break_leaves_a_plain_ruby_block
    player = played(frames: 1) do
      count = 0
      [1, nil, 3].each do |each_number|
        kept = each_number || break
        count += kept
      end
      total = var :total, count
      game_loop { total += 0 }
    end

    assert_equal 1, player[:total]
  end

  def test_and_next_skips_the_rest_of_a_plain_ruby_block
    player = played(frames: 1) do
      count = 0
      [1, 2, 3].each do |each_number|
        each_number == 2 and next
        count += each_number
      end
      total = var :total, count
      game_loop { total += 0 }
    end

    assert_equal 4, player[:total]
  end

  def test_or_return_leaves_a_method
    player = played(frames: 1) do
      def first_given(one) = one || (return 9)
      total = var :total, first_given(nil)
      game_loop { total += 0 }
    end

    assert_equal 9, player[:total]
  end

  def test_the_right_of_and_runs_only_when_the_left_holds
    player = played(frames: 3) do
      n = 0
      seen = 0
      game_loop do
        (n == 99) && (seen += 1)
        n += 1
      end
    end

    assert_equal 0, player[:seen]
  end

  def test_a_test_whose_right_side_does_game_work_is_answered_by_both_sides
    player = played(frames: 3) do
      a = var :a, 5
      count = 0
      both = 0
      left_failed = 0
      right_failed = 0
      game_loop do
        both = 1 if a > 1 && (count += 1) > 0
        left_failed = 1 if a > 9 && (count += 1) > 0
        right_failed = 1 if a > 1 && (count += 1) > 99
      end
    end

    assert_equal [1, 0, 0], %i[both left_failed right_failed].map { |name| player[name] }
    assert_equal 6, player[:count]
  end

  def test_an_either_test_whose_right_side_does_game_work_is_answered_by_both_sides
    player = played(frames: 3) do
      a = var :a, 5
      count = 0
      left_held = 0
      right_held = 0
      neither = 0
      game_loop do
        left_held = 1 if a > 1 || (count += 1) > 0
        right_held = 1 if a > 9 || (count += 1) > 0
        neither = 1 if a > 9 || (count += 1) > 99
      end
    end

    assert_equal [1, 1, 0], %i[left_held right_held neither].map { |name| player[name] }
    assert_equal 6, player[:count]
  end

  def test_a_join_kept_in_a_name_holds_the_answer_of_a_right_side_doing_game_work
    player = played(frames: 2) do
      a = var :a, 5
      count = 0
      seen = 0
      game_loop do
        done = a > 1 && (count += 1) > 0
        seen = 1 if done
      end
    end

    assert_equal 1, player[:seen]
  end

  def test_the_right_of_and_skips_a_list_read_the_left_rules_out
    player = played(frames: 2) do
      things = list :things, capacity: 4, full_of: 0
      things[1] = 7
      i = var :i, 9
      ok = true
      skipped = 1
      found = 0
      game_loop do
        skipped = 0 if i < 4 && things[i] == 0
        i = 1 if i == 9
        found = 1 if ok && things[i] == 7
      end
    end

    assert_equal [1, 1], [player[:skipped], player[:found]]
  end

  def test_the_right_of_or_skips_a_list_read_the_left_decides
    player = played(frames: 1) do
      things = list :things, capacity: 4, full_of: 0
      i = var :i, 9
      seen = 0
      game_loop { seen = 1 if i >= 4 || things[i] == 0 }
    end

    assert_equal 1, player[:seen]
  end

  def test_a_number_changed_under_a_game_test_in_setup_follows_the_test
    player = played do
      hp = var :hp, 5
      taken = 1
      taken = 2 if hp > 3
      left = 1
      left = 2 if hp > 9
      seen_taken = 0
      seen_left = 0
      game_loop do
        seen_taken = taken
        seen_left = left
      end
    end

    assert_equal [2, 1], [player[:seen_taken], player[:seen_left]]
  end

  def test_a_number_changed_under_a_game_test_in_a_method_follows_the_test
    player = played do
      def speed_for(hp)
        s = 1
        before = s
        s = 2 if hp > 3
        s += before
        s
      end
      hp = var :hp, 5
      low = var :low, 1
      seen = 0
      seen_low = 0
      game_loop do
        seen = speed_for(hp)
        seen_low = speed_for(low)
      end
    end

    assert_equal [3, 2], [player[:seen], player[:seen_low]]
  end

  def test_a_name_first_given_a_number_on_both_sides_of_a_game_test_follows_the_test
    player = played do
      hp = var :hp, 5
      seen = 0
      game_loop do
        if hp > 3
          picked = 1
        else
          picked = 2
        end
        seen = picked
      end
    end

    assert_equal 1, player[:seen]
  end

  def test_an_argument_changed_under_a_game_test_follows_the_test
    player = played do
      def later_of(pose, passes)
        pose = 7 if passes >= 2
        pose
      end
      passes = 0
      seen = 0
      game_loop do
        passes += 1
        seen = later_of(1, passes)
      end
    end

    assert_equal 7, player[:seen]
  end

  # The name is read only inside the first test, so that test leaves it alone, and the second has to
  # give it a number of its own: the variable it was started from belongs to the caller.
  def test_a_name_given_an_argument_and_changed_under_a_test_inside_a_test_leaves_the_caller_alone
    player = played do
      def slowed(counter, blinks)
        slow = 0
        if blinks >= 1
          frames = counter
          frames = counter >> 2 if blinks >= 2
          slow = frames
        end
        slow
      end
      counter = var :counter, 8
      blinks = var :blinks, 2
      seen = var :seen, 0
      game_loop { seen = slowed(counter, blinks) }
    end

    assert_equal 8, player[:counter]
    assert_equal 2, player[:seen]
  end

  def test_a_number_changed_under_a_test_inside_a_test_follows_the_test
    player = played do
      passes = var :passes, 0
      seen = var :seen, 0
      game_loop do
        passes += 1
        if passes >= 1
          amount = 3
          amount = 5 if passes >= 2
          seen = amount
        end
      end
    end

    assert_equal 5, player[:seen]
  end

  def test_a_number_changed_in_a_game_loop_inside_a_method_follows_the_test
    player = played do
      def count_up(limit)
        n = 0
        while n < limit
          n += 1
        end
        n
      end
      limit = var :limit, 3
      seen = 0
      game_loop { seen = count_up(limit) }
    end

    assert_equal 3, player[:seen]
  end

  def test_a_name_only_used_under_a_game_test_costs_no_variable
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      hp = var :hp, 5
      seen = 0
      game_loop do
        if hp > 3
          worked = hp + 1
          worked += 1
          seen = worked
        end
      end
    end))
    builder.finalize_program

    refute_includes builder.program.walk.select { |node| node.kind == :var_ref }.map(&:name), :__kept_1
  end

  private def case_on(start, &arms)
    played do
      n = var :n, start
      seen = 0
      game_loop { seen = instance_exec(n, &arms) }
    end[:seen]
  end

  def test_case_on_a_variable_takes_the_arm_the_game_finds
    arms = proc do |n|
      picked = case n
               when 0 then 1
               when 1 then 2
               else 3
               end
      picked
    end

    assert_equal [2, 3], [1, 9].map { |start| case_on(start, &arms) }
  end

  def test_case_takes_a_range_a_comma_list_and_a_list_written_out
    arms = proc do |n|
      picked = case n
               when 0..2 then 1
               when 5, 7 then 2
               when *[9, 10] then 3
               else 4
               end
      picked
    end

    assert_equal [1, 2, 3, 4], [1, 7, 10, 3].map { |start| case_on(start, &arms) }
  end

  def test_case_takes_a_range_with_no_end_or_no_start
    arms = proc do |n|
      picked = case n
               when 7.. then 1
               when ..2 then 2
               when ...4 then 3
               else 4
               end
      picked
    end
    starts = [1, 2, 3, 4, 6, 7, 9]

    assert_equal starts.map(&arms), starts.map { |start| case_on(start, &arms) }
  end

  def test_case_in_takes_a_range_with_no_end_or_no_start
    arms = proc do |n|
      picked = case n
               in 7.. then 1
               in ..2 then 2
               else 3
               end
      picked
    end
    starts = [1, 2, 3, 7, 9]

    assert_equal starts.map(&arms), starts.map { |start| case_on(start, &arms) }
  end

  def test_case_on_a_name_holding_a_symbol
    player = played do
      mode = :title
      seen = 0
      game_loop do
        case mode
        when :title then seen = 1
        when :play then seen = 2
        end
        mode = :play
      end
    end

    assert_equal 2, player[:seen]
  end

  def test_case_with_no_arm_found_and_no_else_does_nothing
    player = played do
      n = var :n, 9
      seen = 0
      game_loop do
        case n
        when 1 then seen = 1
        end
      end
    end

    assert_equal 0, player[:seen]
  end

  def test_case_on_a_working_out
    player = played do
      n = var :n, 1
      seen = 0
      game_loop do
        case n + 1
        when 2 then seen = 5
        else seen = 6
        end
      end
    end

    assert_equal 5, player[:seen]
  end

  def test_case_with_no_subject_asks_each_test
    player = played do
      n = var :n, 4
      seen = 0
      game_loop do
        case
        when n > 9 then seen = 1
        when n > 3, n < 0 then seen = 2
        else seen = 3
        end
      end
    end

    assert_equal 2, player[:seen]
  end

  def test_case_in_takes_a_number_a_range_and_a_choice_of_either
    arms = proc do |n|
      picked = case n
               in 0..2 then 1
               in 5 | 7 then 2
               in 9 then 3
               else 4
               end
      picked
    end

    assert_equal [1, 2, 3, 4], [1, 7, 9, 3].map { |start| case_on(start, &arms) }
  end

  def test_case_in_on_a_plain_value_stays_ruby
    player = played do
      point = { x: 3, y: 4 }
      seen = 0
      case point
      in { x: Integer => across } then seen = across
      end
      shown = 0
      game_loop { shown = seen }
    end

    assert_equal 3, player[:shown]
  end

  def test_for_over_a_range_written_out_goes_round_while_building
    player = played do
      total = 0
      game_loop do
        total = 0
        for each_number in 1..3
          total += each_number
        end
      end
    end

    assert_equal 6, player[:total]
  end

  def test_case_on_a_plain_value_stays_ruby
    player = played do
      kind = "text"
      seen = 0
      case kind
      when Integer then seen = 1
      when String, Symbol then seen = 2
      end
      shown = 0
      game_loop { shown = seen }
    end

    assert_equal 2, player[:shown]
  end

  MovedThing = Struct.new(:x)

  def test_a_splat_unpacks_things_that_are_not_numbers_and_game_code_changes_them
    player = played do
      def things = [MovedThing.new(var(:first_x, 1)), MovedThing.new(var(:second_x, 2)), :extra]
      marker, choice_marker, *rest = things
      seen = 0
      passes = 0
      game_loop do
        marker = choice_marker
        passes += 1
        marker.x = 5
        seen = rest.length
      end
    end

    assert_equal [1, 5, 1], [player[:first_x], player[:second_x], player[:seen]]
  end

  def test_a_splat_and_nested_names_keep_numbers_as_game_variables
    player = played do
      first, *rest = 1, 2, 3
      (inner, other), last = [4, 5], 6
      game_loop do
        first += rest.first
        inner += 1
        other += last
      end
    end

    assert_equal [7, 7, 23], [player[:first], player[:inner], player[:other]]
  end

  def test_multiple_assignment_swaps_on_every_pass
    player = played do
      a = 1
      b = 2
      seen = 0
      game_loop do
        a, b = b, a
        seen += a
      end
    end

    assert_equal 5, player[:seen]
  end

  def test_multiple_assignment_reads_every_right_side_before_it_writes
    player = played do
      a = 1
      b = 1
      game_loop { a, b = b, a + b }
    end

    assert_equal [3, 5], [player[:a], player[:b]]
  end

  def test_multiple_assignment_starts_variables_in_setup
    player = played do
      x, y = 1, 2
      game_loop do
        x += 1
        y += 2
      end
    end

    assert_equal [4, 8], [player[:x], player[:y]]
  end

  def test_multiple_assignment_takes_a_list_a_method_hands_back
    player = played do
      def both = [3, 4]
      x, y = both
      game_loop { x += y }
    end

    assert_equal 15, player[:x]
  end

  def test_multiple_assignment_from_instance_variables_keeps_going_later
    player = played do
      @a = var :from_a, 1
      @b = var :from_b, 2
      a, b = @a, @b
      game_loop do
        a += 1
        @a += b
      end
    end

    assert_equal [4, 7], [player[:a], player[:from_a]]
  end

  def test_multiple_assignment_writes_a_hash_slot_and_an_attribute
    player = played do
      ball = { hp: var(:hp, 5) }
      hero = MovedThing.new(var(:hero_x, 1))
      n = var :n, 3
      game_loop do
        ball[:hp], hero.x = n, n + 1
      end
    end

    assert_equal [3, 4], [player[:hp], player[:hero_x]]
  end

  def test_two_names_given_one_number_are_two_variables
    player = played do
      x = y = 0
      game_loop do
        x += 1
        y += 2
      end
    end

    assert_equal [3, 6], [player[:x], player[:y]]
  end

  def test_the_right_of_or_runs_only_when_the_left_fails
    player = played(frames: 3) do
      n = 0
      seen = 0
      game_loop do
        (n == 0) || (seen += 1)
        n += 1
      end
    end

    assert_operator player[:seen], :>=, 1
    assert_operator player[:seen], :<, player[:n]
  end

  def test_two_tests_joined_still_make_one_test
    player = played(frames: 2) do
      hp = 3
      both = 0
      either = 0
      game_loop do
        both = 1 if hp > 1 && hp < 9
        either = 1 if hp > 9 || hp < 9
        hp += 0
      end
    end

    assert_equal [1, 1], [player[:both], player[:either]]
  end

  def test_a_name_started_outside_game_code_and_changed_by_a_ruby_loop_in_it_is_a_variable
    player = played do
      x = 0
      game_loop do
        3.times { x += 1 }
      end
    end

    assert_equal 9, player[:x]
  end

  def test_a_name_started_in_game_code_and_changed_by_a_ruby_loop_adds_up_while_building
    player = played do
      seen = 0
      game_loop do
        total = 0
        [1, 2, 3].each { |n| total += n }
        seen = total
      end
    end

    assert_equal 6, player[:seen]
  end

  def test_nil_given_a_number_in_game_code_answers_as_the_game_plays
    player = played(frames: 2) do
      target = nil
      a_set = 0
      b_set = 0
      passes = 0
      game_loop do
        a_set = 1 if target
        passes += 1
        target = 5 if passes == 1
        b_set = 1 if target
      end
    end

    assert_equal [1, 1], [player[:a_set], player[:b_set]]
  end

  def test_nil_is_falsy_and_answers_nil_before_a_number_arrives
    player = played(frames: 1) do
      target = nil
      truthy = 0
      unless_ran = 0
      is_nil = 0
      game_loop do
        truthy = 1 if target
        unless_ran = 1 unless target
        is_nil = 1 if target.nil?
        target = 0 if truthy == 5
      end
    end

    assert_equal [0, 1, 1], [player[:truthy], player[:unless_ran], player[:is_nil]]
  end

  def test_zero_is_truthy_in_a_name_that_started_as_nil
    player = played(frames: 2) do
      target = nil
      truthy = 0
      game_loop do
        truthy = 1 if target
        target = 0
      end
    end

    assert_equal 1, player[:truthy]
  end

  def test_nil_clears_a_name_in_game_code
    player = played(frames: 3) do
      target = 5
      passes = 0
      still = 0
      game_loop do
        passes += 1
        target = nil if passes == 2
        still = passes if target
      end
    end

    assert_equal 1, player[:still]
  end

  # Read as a number, nil is 0, whatever number the name held before.
  def test_nil_read_as_a_number_is_0_after_the_name_held_a_number
    player = played(frames: 3) do
      target = nil
      numbered = var(:numbered, 3)
      answers = list(:answers, capacity: 8, full_of: -1)
      pass = 0
      game_loop do
        target = numbered
        target = nil
        answers[pass] = target
        started = nil
        answers[pass + 4] = started
        started = numbered
        pass += 1
      end
    end

    assert_equal [0, 0, 0, 0, 0, 0], player.list(:answers).values_at(0, 1, 2, 4, 5, 6)
  end

  def test_or_on_a_name_that_may_hold_nil_picks_the_number_or_the_other_side
    player = played(frames: 2) do
      target = nil
      first = 0
      later = 0
      passes = 0
      game_loop do
        passes += 1
        first = target || 7 if passes == 1
        target = 3
        later = target || 7
      end
    end

    assert_equal [7, 3], [player[:first], player[:later]]
  end

  def test_a_name_started_as_nil_can_take_something_made_while_building
    player = played(frames: 1) do
      hero = nil
      seen = 0
      image(:hero, "#" => :red) { "#" }
      func :play do
        hero = sprite :hero, at: [1, 2] if hero.nil?
        seen = hero.x
      end
      game_loop { call :play }
    end

    assert_equal 1, player[:seen]
  end

  def test_a_true_or_false_name_given_zero_is_truthy
    player = played do
      ok = true
      seen = 0
      game_loop do
        ok = 0
        seen += 1 if ok
      end
    end

    assert_equal 3, player[:seen]
  end

  def test_a_number_name_given_false_is_falsy
    player = played do
      n = 1
      seen = 0
      game_loop do
        n = false
        seen += 1 if n
      end
    end

    assert_equal 0, player[:seen]
  end

  def test_false_and_nil_are_told_apart_by_nil
    player = played(frames: 1) do
      flag = nil
      was_nil = 0
      game_loop do
        flag = false
        was_nil = 1 if flag.nil?
      end
    end

    assert_equal 0, player[:was_nil]
  end

  def test_a_name_under_a_game_test_with_no_other_side_is_nil_until_it_is_set
    player = played do
      hp = var :hp, 5
      seen = 0
      game_loop do
        if hp > 9
          found = 1
        end
        seen = 1 if found
      end
    end

    assert_equal 0, player[:seen]
  end

  # hp starts at 5, so Ruby's d is 6 and the square is drawn at 6. A name that worked its number
  # out again at the draw would put it at 1.
  def test_d_keeps_the_number_from_its_line_when_hp_changes_before_the_draw
    player = played(frames: 1) do
      hp = var :hp, 5
      game_loop do
        d = hp + 1
        hp = 0
        draw_rect_at d, 10, 2, 2, :green
        halt
      end
    end

    refute_equal 0, player.screen.pixel(6, 10), "drawn at 6, where Ruby says d is"
    assert_equal 0, player.screen.pixel(1, 10), "nothing drawn at 1"
  end

  def test_a_worked_out_number_keeps_its_value_from_its_line
    player = played do
      hp = var :hp, 5
      seen = 0
      game_loop do
        d = hp + 1
        hp = 0
        seen = d
        halt
      end
    end

    assert_equal 6, player[:seen]
  end

  def test_a_test_kept_in_a_name_keeps_its_answer_from_its_line
    player = played do
      hp = var :hp, 5
      seen = 0
      game_loop do
        alive = hp > 0
        hp = 0
        seen = 1 if alive
        halt
      end
    end

    assert_equal 1, player[:seen]
  end

  def test_a_copy_made_in_setup_does_not_follow_what_it_came_from
    player = played do
      hp = var :hp, 5
      first = hp
      seen = 0
      game_loop do
        hp -= 1
        seen = first
      end
    end

    assert_equal [2, 5], [player[:hp], player[:seen]]
  end

  def test_a_worked_out_number_made_in_setup_keeps_its_value
    player = played do
      @hp = var :hp, 5
      next_hp = @hp + 1
      seen = 0
      game_loop do
        @hp -= 1
        seen = next_hp
      end
    end

    assert_equal 6, player[:seen]
  end

  def test_a_name_read_before_what_it_came_from_changes_costs_no_variable
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      hp = var :hp, 5
      seen = 0
      game_loop do
        d = hp + 1
        seen = d
        hp = 0
      end
    end))
    builder.finalize_program

    assert_empty builder.hidden_variable_notes
  end

  def test_a_second_name_nothing_changes_costs_no_variable
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      hp = var :hp, 5
      first = hp
      seen = 0
      game_loop { seen = first }
    end))
    builder.finalize_program

    assert_empty builder.hidden_variable_notes
  end

  def test_a_method_ending_in_a_ternary_on_a_game_test_gives_back_the_answer
    player = played do
      def alive(hp) = hp > 0 ? true : false
      def speed(hp)
        hp > 3 ? 2 : 1
      end
      hp = var :hp, 5
      none = var :none, 0
      seen_alive = 0
      seen_dead = 0
      fast = 0
      slow = 0
      game_loop do
        seen_alive = 1 if alive(hp)
        seen_dead = 1 if alive(none)
        fast = speed(hp)
        slow = speed(none)
      end
    end

    assert_equal [1, 0, 2, 1], %i[seen_alive seen_dead fast slow].map { |name| player[name] }
  end

  def test_a_method_ending_in_a_ternary_of_two_variables_gives_back_the_number
    player = played do
      def pick(hp, lives, first) = first > 0 ? hp : lives
      hp = var :hp, 5
      lives = var :lives, 3
      yes = var :yes, 1
      no = var :no, 0
      from_hp = 0
      from_lives = 0
      game_loop do
        from_hp = pick(hp, lives, yes)
        from_lives = pick(hp, lives, no)
      end
    end

    assert_equal [5, 3], [player[:from_hp], player[:from_lives]]
  end

  private def hidden_notes_of(allow: [], &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, allow: allow))
    builder.finalize_program
    builder.hidden_variable_notes
  end

  def test_picking_into_a_game_variable_needs_no_hidden_variable
    player = played do
      hp = var :hp, 5
      x = 0
      y = 0
      z = 0
      game_loop do
        x = hp > 3 ? 1 : 2
        y = if hp > 9 then 3 else 4 end
        z = case hp
            when 5 then 6
            else 7
            end
      end
    end
    notes = hidden_notes_of do
      hp = var :hp, 5
      x = 0
      game_loop { x = hp > 3 ? 1 : 2 }
    end

    assert_equal [1, 4, 6], [player[:x], player[:y], player[:z]]
    assert_empty notes
  end

  def test_a_side_of_a_pick_can_read_the_variable_it_goes_into
    player = played do
      hp = var :hp, 5
      x = 10
      game_loop { x = hp > 3 ? x + 1 : 0 }
    end

    assert_equal 13, player[:x]
  end

  def test_a_join_into_a_game_variable_needs_no_hidden_variable
    player = played do
      a = var :a, 5
      count = 0
      done = false
      game_loop { done = a > 1 && (count += 1) > 0 }
    end
    notes = hidden_notes_of do
      a = var :a, 5
      count = 0
      done = false
      game_loop { done = a > 1 && (count += 1) > 0 }
    end

    assert_equal [1, 3], [player[:done], player[:count]]
    assert_empty notes
  end

  def test_a_name_holding_only_nil_true_and_false_needs_no_hidden_variable
    player = played(frames: 2) do
      flag = nil
      seen = 0
      passes = 0
      game_loop do
        seen = 1 if flag
        passes += 1
        flag = true if passes == 1
        flag = nil if passes == 2
      end
    end
    notes = hidden_notes_of do
      flag = nil
      game_loop { flag = true if pressed(:a) }
    end

    assert_equal 1, player[:seen]
    assert_empty notes
  end

  def test_a_name_asked_nil_tells_nil_from_false
    notes = hidden_notes_of do
      flag = nil
      seen = 0
      game_loop do
        flag = false if pressed(:a)
        seen = 1 if flag.nil?
      end
    end

    assert_equal 1, notes.length
  end

  # `== nil` and `!= nil` ask what `nil?` asks, on every pass, either way round.
  def test_a_name_compared_with_nil_answers_as_nil_does
    game = proc do
      target = nil
      passes = 0
      empty = 0
      held = 0
      game_loop do
        passes += 1
        target = 5 if passes == 3
        empty = target == nil ? 1 : 0
        held = nil != target ? 1 : 0
      end
    end

    before = played(frames: 2, &game)
    after = played(frames: 4, &game)

    assert_equal [1, 0], [before[:empty], before[:held]]
    assert_equal [0, 1], [after[:empty], after[:held]]
  end

  def test_a_write_on_the_right_of_a_join_under_a_game_test_follows_the_test
    player = played do
      def nudged(a)
        x = 1
        a > 3 && x = 2
        x
      end
      high = var :high, 5
      low = var :low, 1
      seen_high = 0
      seen_low = 0
      game_loop do
        seen_high = nudged(high)
        seen_low = nudged(low)
      end
    end

    assert_equal [2, 1], [player[:seen_high], player[:seen_low]]
  end

  def test_a_swap_of_a_fraction_keeps_the_fraction
    player = played do
      a = 1.5
      b = 2.5
      seen = 0
      game_loop do
        a, b = b, a
        seen = (b * 2).to_i
      end
    end

    assert_equal 3, player[:seen]
  end

  def test_a_swap_of_a_name_that_may_hold_nil_is_listed_as_a_swap
    notes = hidden_notes_of do
      a = nil
      b = 2
      game_loop { a, b = b, a }
    end

    assert_includes notes.map(&:why), :swap
  end

  def test_a_method_ending_in_a_ternary_of_verbs_still_runs_one_side
    player = played do
      def nudge(hp, tally) = hp > 3 ? tally[:high] += 1 : tally[:low] += 1
      hp = var :hp, 5
      tally = { high: var(:high, 0), low: var(:low, 0) }
      game_loop { nudge(hp, tally) }
    end

    assert_equal [3, 0], [player[:high], player[:low]]
  end

  def test_an_ivar_made_with_or_equals_copies_another_variable
    player = played do
      @a = var :a, 5
      @b ||= var :b, 0
      @b = @a
      game_loop { @a += 1 }
    end

    assert_equal [8, 5], [player[:a], player[:b]]
  end

  def test_a_fraction_changed_under_a_game_test_keeps_its_fraction
    player = played do
      hp = var :hp, 5
      speed = var :speed, 1.5
      seen = 0
      game_loop do
        step = speed
        step = step + 1 if hp > 3
        seen = (step * 2).to_i
      end
    end

    assert_equal 5, player[:seen]
  end

  def test_a_fraction_kept_from_its_line_keeps_its_fraction
    player = played do
      speed = var :speed, 1.5
      seen = 0
      game_loop do
        kept = speed + 1
        speed = 0.0
        seen = (kept * 2).to_i
        halt
      end
    end

    assert_equal 5, player[:seen]
  end

  # A name set from an item of a table at a place the game moves on before the name is used: read
  # again where it is used, `flags` and `byte` would be the next item. Each read here is the one
  # before `at` moved: a flag of 0b0101 picks 10 and 30, where the next byte, 10, would pick 20.
  # A place moved by `spot.increase!(1)` is moved as `+=` moves one.
  def test_a_name_set_from_an_item_at_a_place_that_moves_on_keeps_that_item
    player = played(frames: 2) do
      packed = table :packed, [0b0101, 10, 20, 30, 40], width: :byte
      @kept = table :kept, [7, 8], width: :byte
      out = list :unpacked, capacity: 4, full_of: 0
      first = var :first, 0
      second = var :second, 0
      spot = var :spot, 0
      game_loop do
        at = 0
        flags = packed[at]
        at += 1
        4.times do |bit|
          byte = packed[at]
          at += 1
          out[bit] = byte if flags & (1 << bit) != 0
        end
        place = 0
        held = @kept[place]
        place += 1
        first = held
        spot.store!(0)
        spotted = packed[spot]
        spot.increase!(1)
        second = spotted
        halt
      end
    end

    assert_equal [10, 0, 30, 0], player.list(:unpacked)
    assert_equal [7, 5], [player[:first], player[:second]]
  end

  # `out[j] = 99` writes the slot `held` was read from, since j is i: `held` keeps the 5 it read.
  # A slot read at a key written out is changed by a write at a key worked out the same way.
  def test_a_name_set_from_a_slot_keeps_it_when_the_slot_is_written_at_another_key
    player = played(frames: 2) do
      out = list :out, capacity: 2, full_of: 5
      first = var :first, 0
      second = var :second, 0
      game_loop do
        i = 0
        j = 0
        i += 0
        j += 0
        held = out[i]
        out[j] = 99
        first = held
        out[1] = 5
        fixed = out[1]
        out[j + 1] = 77
        second = fixed
        halt
      end
    end

    assert_equal [5, 5], [player[:first], player[:second]]
  end

  # `bump(at)` moves `at` on inside a method of the game, between the line that sets `flags` and
  # the line that uses it: `flags` holds the 10 read before, where the next item would be 20.
  def test_a_name_set_from_an_item_keeps_it_when_a_method_moves_the_place_on
    player = played(frames: 2) do
      def bump(place) = place.increase!(1)
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        flags = packed[at]
        bump(at)
        seen = flags
        halt
      end
    end

    assert_equal [10, 1], [player[:seen], player[:at]]
  end

  # `mover.move_place_on(at)` moves `at` on through a method of an object of the game's, defined in
  # another file (test/plain_ruby_helper_part.rb): `flags` holds the 10 read before, not the 20.
  def test_a_name_set_from_an_item_keeps_it_when_an_objects_method_moves_the_place_on
    player = played(frames: 2, allow: %w[PlainRubyPlaceMover]) do
      mover = PlainRubyPlaceMover.new
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        flags = packed[at]
        mover.move_place_on(at)
        seen = flags
        halt
      end
    end

    assert_equal [10, 1], [player[:seen], player[:at]]
  end

  # `frame` is set while setting up from the count VBlank keeps up each frame, and read in the game
  # loop after a method of another file that could change anything: it still follows the count, as
  # a game reading it live wants. Copied there, it would hold the 0 it was set up on, and a game
  # waiting on it would wait for ever.
  def test_a_name_set_up_from_the_frame_count_follows_it_across_a_call_of_another_files_method
    player = played(frames: 4) do
      frame = frames_since_power_on
      seen = var :seen, 0
      game_loop do
        plain_ruby_helper_pass_over(0)
        seen = frame
      end
    end

    assert_operator player[:seen], :>=, 2
  end

  # `start` is set while setting up from `hero`, which the routine called in the loop moves on, and
  # the routine is made above it: `start` holds the 5 it was set to, as Ruby's would.
  def test_a_name_set_up_from_a_number_a_called_routine_moves_holds_its_start
    player = played(frames: 2) do
      hero = var :hero, 5
      func(:move_hero) { hero += 1 }
      start = hero + 0
      seen = var :seen, 0
      game_loop do
        call :move_hero
        seen = start
        halt
      end
    end

    assert_equal [5, 6], [player[:seen], player[:hero]]
  end

  # A call that cannot write what `flags` was read from leaves `flags` a working-out, which costs
  # no variable: a method that writes nothing, a routine that writes another name, an object's
  # method handed another name, and a method that moves `at` on the other side of an `if` from the
  # read. Each `flags` still holds the 10 it read.
  def test_a_name_read_across_calls_that_cannot_change_it_takes_no_copy
    game = proc do
      def tile_of(code) = code + 1
      def bump(place) = place.increase!(1)
      mover = PlainRubyPlaceMover.new
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      other = var :other, 0
      seen = var :seen, 0
      sided = var :sided, 0
      func(:step_other) { other += 1 }
      game_loop do
        flags = packed[at]
        tile_of(3)
        call :step_other
        mover.move_place_on(other)
        seen = flags
        held = packed[at]
        if other > 100
          bump(at)
        else
          sided = held
        end
        halt
      end
    end

    assert_empty hidden_notes_of(allow: %w[PlainRubyPlaceMover], &game)
    player = played(frames: 2, allow: %w[PlainRubyPlaceMover], &game)

    assert_equal [10, 10, 2], [player[:seen], player[:sided], player[:other]]
  end

  # `floors` is the game variable a method hands back, as a port's unpacking keeps its counts:
  # counted up with `increase!` across calls of another file's method, it is that variable, so
  # `counted` ends at 3 and so does the slot it is written into. A copy would count up apart.
  # `before`, read from `floors` and handed to a method that counts it on, keeps the 0 it read.
  def test_a_variable_a_method_hands_back_counts_itself_across_calls
    player = played(frames: 2) do
      def count_on(count) = count.increase!(1)
      counted = var :counted, 0
      counts = list :counts, capacity: 2, full_of: 0
      game_loop do
        floors = plain_ruby_helper_pass_over(counted)
        floors.store!(0)
        before = floors + 0
        repeat(2) do
          plain_ruby_helper_pass_over(0)
          floors.increase!(1)
        end
        count_on(floors)
        counts[0] = floors
        counts[1] = before
        halt
      end
    end

    assert_equal [3, [3, 0]], [player[:counted], player.list(:counts)]
  end

  # A song reader of another file (PlainRubySongReader, test/plain_ruby_helper_part.rb) reads and
  # moves each channel's place only through its own methods, `get` and `set`, on lists it reaches
  # through a Hash. `at` holds the place before `set` moves it, and `high` the byte before the
  # second read: channel 0's pitch offset is 0x0001, from bytes 0x00 then 0x01, and its place
  # ends two bytes on. Read late, each byte would be the next one (0x0102).
  def test_a_name_read_through_a_method_keeps_it_when_another_method_moves_the_place_on
    player = played(frames: 2, allow: %w[PlainRubySongReader]) do
      bytes = table :song_bytes, [0x00, 0x01, 0x02, 0x03, 0x04], width: :byte
      reader = PlainRubySongReader.new(self, bytes)
      game_loop do
        reader.read_pitch_offset(0)
        halt
      end
    end

    assert_equal [0x0001, 0], player.list(:song_pitch_offset)
    assert_equal [2, 0], player.list(:song_at)
  end

  # The same reader's drum step: `envelope` and `noise` are read at places worked out from `at`,
  # itself read through `get`, and `set` moves the drum place on before they are written. They
  # hold the bytes after the step's first, 0x11 and 0x12, where the next step's would be 0x14 and
  # 0x15.
  def test_a_name_read_through_another_name_keeps_it_when_a_method_moves_the_place_on
    player = played(frames: 2, allow: %w[PlainRubySongReader]) do
      bytes = table :song_bytes, [0x10, 0x11, 0x12, 0x13, 0x14, 0x15], width: :byte
      reader = PlainRubySongReader.new(self, bytes)
      game_loop do
        reader.read_drum_step(0)
        halt
      end
    end

    assert_equal [[0x11, 0], [0x12, 0], [3, 0]],
                 [player.list(:song_envelope), player.list(:song_noise), player.list(:song_drum)]
  end

  # `bump(at)` moves `at` on later in the line that sets `f`: the `f` read after it holds the 10
  # read before, so the line adds 10, 0 and 10. Read late, both would be 20.
  def test_a_name_set_inside_a_line_keeps_it_when_a_call_later_in_the_line_moves_the_place_on
    player = played(frames: 2) do
      def bump(place)
        place.increase!(1)
        0
      end
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      total = var :total, 0
      game_loop do
        at.store!(0)
        total = (f = packed[at]) + bump(at) + f
        halt
      end
    end

    assert_equal [20, 1], [player[:total], player[:at]]
  end

  # `call :step_on` runs a routine that moves `at` on, between the line that sets `flags` and the
  # line that uses it: `flags` holds the 10 read before, where the next item would be 20.
  def test_a_name_set_from_an_item_keeps_it_when_a_called_routine_moves_the_place_on
    player = played(frames: 2) do
      packed = table :packed, [10, 20, 30], width: :byte
      at = 0
      seen = var :seen, 0
      func(:step_on) { at += 1 }
      game_loop do
        at = 0
        flags = packed[at]
        call :step_on
        seen = flags
        halt
      end
    end

    assert_equal [10, 1], [player[:seen], player[:at]]
  end

  # A method that reads the item at a place kept in a list reached through a Hash, then moves the
  # place on, as an unpacking routine reads its next byte. `at` holds the place before the move, so
  # each call hands back the next item: 1, then 2 and 3 joined into 0x0203. Read late, `at` would
  # be the moved place, and `high` would be read again after the second call moved it. The same
  # routine in a game file, reading a copy, is FlaggedByteReader (test/plain_ruby_flagged_bytes_part.rb).
  def test_a_name_set_from_a_place_kept_in_a_list_holds_it_when_the_place_moves_on
    player = played(frames: 2) do
      def next_item(state, packed, channel)
        at = state.fetch(:at)[channel]
        state.fetch(:at)[channel] = at + 1
        packed[at]
      end
      packed = table :packed, [1, 2, 3, 4], width: :byte
      state = { at: list(:places, capacity: 2, full_of: 0) }
      first = var :first, 0
      pair = var :pair, 0
      game_loop do
        first = next_item(state, packed, 0)
        high = next_item(state, packed, 0)
        pair = (high << 8) | next_item(state, packed, 0)
        halt
      end
    end

    assert_equal [1, 0x0203], [player[:first], player[:pair]]
  end

  # The answer key for the tests below is Ruby: the same lines run as plain Ruby on Integers, a `var`
  # an object that answers `increase!`. A local keeps the number of its line however the code
  # around it calls, branches or hands things on.

  # `stepper.step` is a method of an object of another file (PlainRubyStepper) named like Ruby's
  # Integer#step, which moves on the place the object was made with: `flags` keeps the 10.
  def test_a_name_keeps_its_number_across_a_game_method_named_like_one_of_rubys
    player = played(frames: 2, allow: %w[PlainRubyStepper]) do
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      stepper = PlainRubyStepper.new(at)
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        flags = packed[at]
        stepper.step
        seen = flags
        halt
      end
    end

    assert_equal [10, 1], [player[:seen], player[:at]]
  end

  # An object of another file kept the Hash it was made with (PlainRubySharedPlace), and moves on
  # the place kept in it: `place` keeps the 0 it read.
  def test_a_name_keeps_its_number_when_an_object_moves_what_it_was_handed_as_it_was_made
    player = played(frames: 2, allow: %w[PlainRubySharedPlace]) do
      state = { at: list(:places, capacity: 1, full_of: 0) }
      mover = PlainRubySharedPlace.new(state)
      seen = var :seen, 9
      game_loop do
        place = state.fetch(:at)[0]
        mover.advance
        seen = place
        halt
      end
    end

    assert_equal [0, [1]], [player[:seen], player.list(:places)]
  end

  # `item` is handed to a method that moves the place on before it reads its argument: the
  # method reads the 10 `item` was set to.
  def test_a_name_handed_to_a_method_keeps_its_number_when_the_method_moves_its_source_first
    player = played(frames: 2) do
      def bump_then_give(place, item)
        place.increase!(1)
        item
      end
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        item = packed[at]
        seen = bump_then_give(at, item)
        halt
      end
    end

    assert_equal [10, 1], [player[:seen], player[:at]]
  end

  # `held` is set on the first round of a loop, on one side of an `if`, before a call moves its
  # place on; the second round reads it on the other side, and gets the 10.
  def test_a_name_set_on_one_round_keeps_its_number_on_the_other_side_of_an_if_next_round
    player = played(frames: 2) do
      def bump(place) = place.increase!(1)
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      round = var :round, 0
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        round.store!(0)
        held = 0
        while round < 2
          if round == 0
            held = packed[at]
            bump(at)
          else
            seen = held
          end
          round += 1
        end
        halt
      end
    end

    assert_equal 10, player[:seen]
  end

  # `start` and `answer` are set while setting up, and a method of another file moves their place
  # on in the game loop before they are read: each keeps the 10 of its line.
  def test_a_name_set_up_keeps_its_number_across_a_call_of_another_files_method
    player = played(frames: 2) do
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      start = packed[at]
      answer = plain_ruby_helper_pass_over(packed[at])
      seen = var :seen, 0
      seen_answer = var :seen_answer, 0
      game_loop do
        plain_ruby_helper_move_on(at)
        seen = start
        seen_answer = answer
        halt
      end
    end

    assert_equal [10, 10, 1], [player[:seen], player[:seen_answer], player[:at]]
  end

  # A list handed through a method's argument to a method that changes it: `first` keeps the 5.
  def test_a_name_keeps_its_number_when_a_list_handed_on_through_an_argument_changes
    player = played(frames: 2) do
      def bump_first(list)
        list[0] += 1
      end

      def first_then_bump(list)
        first = list[0]
        bump_first(list)
        first
      end
      counts = list :counts, capacity: 1, full_of: 5
      seen = var :seen, 0
      game_loop do
        seen = first_then_bump(counts)
        halt
      end
    end

    assert_equal [5, [6]], [player[:seen], player.list(:counts)]
  end

  # `x` is read through two methods that call each other, and changed through two more: it keeps
  # the 5.
  def test_a_name_keeps_its_number_across_methods_that_call_each_other
    player = played(frames: 2) do
      def pick(list, depth) = depth.zero? ? list[0] : pock(list, depth - 1)
      def pock(list, depth) = pick(list, depth)
      def push(list, depth) = depth.zero? ? (list[0] += 1) : pash(list, depth - 1)
      def pash(list, depth) = push(list, depth)
      counts = list :counts, capacity: 1, full_of: 5
      seen = var :seen, 0
      game_loop do
        x = pick(counts, 1)
        push(counts, 1)
        seen = x
        halt
      end
    end

    assert_equal [5, [6]], [player[:seen], player.list(:counts)]
  end

  # `place` is changed by `+=` and read by the line that sets `item`, and a call moves `at`, which
  # `place` was worked out from: `item` keeps the 20 at place 1.
  def test_a_name_read_through_a_name_changed_by_add_keeps_its_number
    player = played(frames: 2) do
      def bump(place) = place.increase!(1)
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      seen = var :seen, 0
      game_loop do
        at.store!(0)
        place = at + 0
        place += 1
        item = packed[place]
        bump(at)
        seen = item
        halt
      end
    end

    assert_equal 20, player[:seen]
  end

  # `out` keeps the 10 it read in a copy of its own, since a method moves its place on; `bend` is
  # given `out` and then 0 under a test the game makes, inside another: `out` keeps its 10.
  def test_a_name_given_another_names_copy_and_then_0_leaves_the_other_alone
    player = played(frames: 2) do
      def bump(place) = place.increase!(1)
      packed = table :packed, [10, 20, 30], width: :byte
      at = var :at, 0
      flag = var :flag, 0
      seen = var :seen, 9
      kept = var :kept, 0
      game_loop do
        at.store!(0)
        out = packed[at]
        bump(at)
        if flag == 0
          bend = out
          bend = 0 if flag == 0
          seen = bend
        end
        kept = out
        halt
      end
    end

    assert_equal [0, 10], [player[:seen], player[:kept]]
  end

  # `n` and `first` are read from a list before `push` and `shift` change it: each keeps its number.
  def test_a_name_keeps_its_number_across_a_change_a_lists_own_method_makes
    player = played(frames: 2) do
      queue = list :queue, capacity: 4
      seen_length = var :seen_length, 0
      seen_first = var :seen_first, 0
      game_loop do
        queue.push(7)
        queue.push(8)
        n = queue.length
        first = queue[0]
        queue.push(9)
        queue.shift
        seen_length = n
        seen_first = first
        halt
      end
    end

    assert_equal [2, 7], [player[:seen_length], player[:seen_first]]
  end

  # `score_at_start` is set up from @score and handed to a verb that reads the number, not to a
  # part that keeps it: it keeps the 5 of its line while the game counts @score on.
  def test_a_name_set_up_and_handed_to_a_verb_keeps_its_number
    player = played(frames: 3) do
      game_variables :score
      @score = 5
      score_at_start = @score
      seen = var :seen, 0
      game_loop do
        @score += 1
        seen = plain_ruby_helper_pass_over(score_at_start)
      end
    end

    assert_equal 5, player[:seen]
  end

  def test_an_ivar_made_by_var_copies_another_variable
    player = played do
      @a = var :a, 5
      @b = var :b, 0
      @b = @a
      game_loop { @a += 1 }
    end

    assert_equal [8, 5], [player[:a], player[:b]]
  end

  def test_an_ivar_made_by_var_on_a_builder_copies_a_local_variable
    player = played do
      build = self
      velocity = var :velocity, 7
      @move = build.var :move, 0
      @move = velocity
      @move = 3
      game_loop { wait_vblank }
    end

    assert_equal [7, 3], [player[:velocity], player[:move]]
  end

  def test_a_right_side_doing_game_work_in_a_method_runs_only_when_the_left_holds
    player = played do
      @distance = var :distance, 0
      def within_reach(from, reach)
        @distance = from
        @distance < reach
      end
      near = var :near, 1
      far = var :far, 9
      left_held = 0
      left_failed = 0
      game_loop do
        left_held = 1 if near < 5 && within_reach(near, 3)
        left_failed = 1 if far < 5 && within_reach(far, 3)
      end
    end

    assert_equal [1, 0, 1], [player[:left_held], player[:left_failed], player[:distance]]
  end

  def test_an_either_right_side_doing_game_work_in_a_method_runs_only_when_the_left_fails
    player = played do
      @distance = var :distance, 0
      def within_reach(from, reach)
        @distance = from
        @distance < reach
      end
      near = var :near, 1
      far = var :far, 9
      left_held = 0
      left_failed = 0
      game_loop do
        left_held = 1 if near < 5 || within_reach(far, 3)
        left_failed = 1 if far < 5 || within_reach(near, 3)
      end
    end

    assert_equal [1, 1, 1], [player[:left_held], player[:left_failed], player[:distance]]
  end

  # While setting up a name can still be pointed anywhere. In game code that is refused, in
  # TestPlainRubyRefusals, since it would record nothing.
  def test_an_ivar_given_another_variable_while_setting_up_moves_to_it
    player = played(frames: 2) do
      a = var :a, 1
      b = var :b, 2
      @focus = a
      @focus = b
      seen = 0
      game_loop do
        seen = @focus
        a += 0
        b += 0
      end
    end

    assert_equal [1, 2], [player[:a], player[:seen]]
  end

  # A plain test while setting up runs one side, so this is one declaration, as if it were written
  # alone. Game code changing it changes that variable.
  def test_a_declaration_picked_by_a_plain_test_is_one_variable
    big = true
    player = played(frames: 2, allow: %i[big]) do
      hits = big ? var(:hits, 10) : var(:hits, 1)
      game_loop { hits += 1 }
    end

    assert_operator player[:hits], :>, 10
  end

  def test_a_picked_value_in_parentheses_is_kept
    player = played(frames: 2) do
      hp = 3
      y = 0
      game_loop do
        y = (hp > 3 ? 2 : 7)
        hp += 0
      end
    end

    assert_equal 7, player[:y]
  end

  def test_begin_end_while_runs_its_body_first
    player = played(frames: 1) do
      count = 0
      begin
        count += 1
      end while count > 5
      total = var :total, count
      game_loop { total += 0 }
    end

    assert_equal 1, player[:total]
  end

  def test_or_equals_sets_a_yes_or_no_that_is_false
    player = played(frames: 3) do
      n = 0
      latched = false
      game_loop do
        latched ||= n == 0
        n += 1
      end
    end

    assert_equal 1, player[:latched]
  end

  def test_or_equals_leaves_a_number_alone_as_it_is_truthy
    player = played(frames: 2) do
      n = 5
      game_loop do
        n ||= 9
        n += 0
      end
    end

    assert_equal 5, player[:n]
  end

  def test_a_name_started_from_a_symbol_is_a_variable
    player = played(frames: 2) do
      mode = :title
      seen = 0
      game_loop do
        seen = 1 if mode == :playing
        mode = :playing
      end
    end

    assert_equal 1, player[:seen]
  end

  NEGATIVE = -4

  def test_a_name_started_from_a_constant_turned_round_is_a_variable
    player = played(frames: 2) do
      x = -NEGATIVE
      y = NEGATIVE.abs
      game_loop do
        x += 1
        y += 1
      end
    end

    assert_operator player[:x], :>, 4
    assert_operator player[:y], :>, 4
  end

  def test_a_number_handed_in_is_truthy_even_at_zero
    player = played(frames: 2) do
      def count_if_there(tally, by)
        tally[:seen] += 1 if by
      end
      zero = var :zero, 0
      tally = { seen: var(:seen, 0) }
      game_loop { count_if_there(tally, zero) }
    end

    assert_operator player[:seen], :>=, 1
  end

  Held = Data.define(:number)

  def test_a_number_kept_in_an_object_is_truthy_even_at_zero
    player = played(frames: 2) do
      held = Held.new(number: var(:zero, 0))
      seen = 0
      game_loop { seen = 1 if held.number }
    end

    assert_equal 1, player[:seen]
  end

  def test_and_or_not_combine_tests_anywhere_a_test_is_made
    player = played(frames: 2) do
      n = 3
      both = 0
      either = 0
      neither = 0
      kept = 0
      game_loop do
        both = 1 if n > 2 && n < 4
        either = 1 if n == 0 || n == 3
        neither = 1 if !(n == 0) && !(n == 1)
        high = n > 2
        low = n < 1
        kept = 1 if high && !low
        kept = 2 if high && low
        n = 3
      end
    end

    assert_equal [1, 1, 1, 1], [player[:both], player[:either], player[:neither], player[:kept]]
  end

  def test_a_plain_value_beside_a_game_test_decides_at_build_time
    open_door = true
    shut_door = false
    player = played(frames: 2) do
      n = 3
      a = 0
      b = 0
      game_loop do
        a = 1 if n == 3 && open_door
        b = 1 if n == 3 && shut_door
        n = 3
      end
    end

    assert_equal [1, 0], [player[:a], player[:b]]
  end

  def test_while_loops_on_a_game_test_and_skips_a_test_already_false
    player = played(frames: 2) do
      n = 4
      m = 0
      passes = 0
      none = 0
      game_loop do
        while n > 0
          n -= 1
          passes += 1
        end
        while m > 0
          none += 1
          m -= 1
        end
      end
    end

    assert_equal 4, player[:passes]
    assert_equal 0, player[:none]
  end

  # `count < 5 && marks[count] != 9`: the right side reads a list at a place the loop moves on,
  # so it is worked out under the left, and its answer is asked afresh on every round, as Ruby's.
  # The first stops at the 9, the second at its bound, the third at the 9 though it starts on 9.
  def test_a_while_joined_with_and_asks_both_sides_each_round
    player = played(frames: 2) do
      marks = list :marks, capacity: 8, width: :byte, full_of: 0
      to_nine = var(:to_nine, 0)
      to_bound = var(:to_bound, 0)
      past_one = var(:past_one, 0)
      game_loop do
        marks[0] = 1
        marks[1] = 2
        marks[2] = 9
        count = 0
        count += 1 while count < 5 && marks[count] != 9
        to_nine.store!(count)
        count = 0
        count += 1 until count >= 5 || marks[count] == 7
        to_bound.store!(count)
        count = 2
        begin
          count += 1
        end while count < 5 && marks[count] != 0
        past_one.store!(count)
      end
    end

    assert_equal [2, 5, 3], [player[:to_nine], player[:to_bound], player[:past_one]]
  end

  # ...and one that waits for a frame in its body goes on from the wait, a round a frame.
  def test_a_while_joined_with_and_goes_on_after_a_wait_in_its_body
    player = played(frames: 8) do
      marks = list :marks, capacity: 8, width: :byte, full_of: 0
      marks[3] = 9
      rounds = var(:rounds, 0)
      count = 0
      while count < 5 && marks[count] != 9
        count += 1
        rounds.increase!(1)
        wait_vblank
      end
      game_loop { wait_vblank }
    end

    assert_equal 3, player[:rounds]
  end

  def test_a_wait_inside_a_while_lets_frames_pass_while_it_goes_round
    player = played(frames: 4) do
      n = 0
      after = 0
      game_loop do
        while n < 100
          n += 1
          wait_vblank
        end
        after = 1
      end
    end

    assert_operator player[:n], :<, 10
    assert_equal 0, player[:after]
  end

  def test_until_stops_once_the_test_holds
    player = played(frames: 2) do
      n = 0
      game_loop do
        until n >= 3
          n += 1
        end
      end
    end

    assert_equal 3, player[:n]
  end

  def test_conditionals_on_plain_values_stay_plain_ruby
    player = played(frames: 2) do
      count = 0
      count += 1 while count < 3
      picked = if count == 3 then 10 else 20 end
      kept = count > 100 ? 1 : 2
      shown = 0
      game_loop { shown = picked + kept }
    end

    assert_equal 12, player[:shown]
  end

  def test_a_local_first_set_in_a_build_time_branch_outlives_it
    player = played(frames: 2) do
      if screen_width > 0
        wide = 8
      end
      shown = 0
      game_loop { shown = wide }
    end

    assert_equal 8, player[:shown]
  end

  def test_a_heredoc_inside_a_branch_keeps_its_lines_once_each
    player = played(frames: 1) do
      rows = 0
      if screen_width > 0
        art = <<~ART
          one
          two
        ART
        rows = art.lines.length
      end
      shown = 0
      game_loop { shown = rows }
    end

    assert_equal 2, player[:shown]
  end

  def test_every_changing_operator_changes_the_real_variable
    player = played(frames: 1) do
      added = 5
      taken = 5
      timed = 5
      bits = 5
      game_loop do
        added += 2
        taken -= 2
        timed *= 2
        bits |= 2
      end
    end

    assert_equal [7, 3, 10, 7], [player[:added], player[:taken], player[:timed], player[:bits]]
  end

  def test_a_game_variable_kept_in_a_hash_or_array_is_changed_where_it_stands
    player = played(frames: 1) do
      ball = { x: var(:x, 1), y: var(:y, 1) }
      pair = [var(:first, 1), var(:second, 1)]
      game_loop do
        ball[:x] = 5
        ball[:y] += 2
        pair[0] = 7
        pair[1] -= 1
      end
    end

    assert_equal [5, 3, 7, 0], [player[:x], player[:y], player[:first], player[:second]]
  end

  # The slots are never written: the variable they hold takes the number, so a frozen Hash or
  # Array of a part's variables works, under a test the game makes or not.
  def test_a_game_variable_in_a_frozen_hash_or_array_is_changed_where_it_stands
    player = played(frames: 2) do
      ball = { x: var(:x, 1), y: var(:y, 1) }.freeze
      pair = [var(:first, 1), var(:second, 1)].freeze
      turn = 0
      game_loop do
        turn += 1
        ball[:x] = 5 if turn == 1
        ball[:y] += 2 if turn == 9
        pair[0] = 7 if turn == 1
        pair[1] -= 1
      end
    end

    assert_equal [5, 1, 7, -1], [player[:x], player[:y], player[:first], player[:second]]
  end

  # A name first given inside a branch has nothing to promote before that branch.
  def test_a_name_first_given_in_a_branch_is_written_through_in_that_branch
    pick = 2
    holder = Struct.new(:size).new(1)
    player = played(frames: 1) do
      total = 0
      case pick
      when 1 then total = 1
      when 2
        if pick == 2
          spot = [1, 2]
          spot[0] = 5
          at = 1
          spot[at] = 6
          box = holder
          box.size = 7
          found = { size: 1 } and found[:size] = 8
          total = spot[0] + spot[1] + box.size + found[:size]
        end
      end
      shown = 0
      game_loop { shown = total }
    end

    assert_equal 26, player[:shown]
  end

  def test_a_plain_number_in_a_frozen_hash_under_a_game_test_stays_ruby_s_error
    assert_raises(FrozenError) do
      played(frames: 1) do
        ball = { x: 1 }.freeze
        turn = 0
        game_loop do
          turn += 1
          ball[:x] = 5 if turn == 1
        end
      end
    end
  end

  def test_a_plain_hash_and_array_stay_plain
    player = played(frames: 1) do
      sizes = { wide: 1 }
      sizes[:wide] += 2
      sizes[:tall] = 4
      shown = 0
      game_loop { shown = sizes[:wide] + sizes[:tall] }
    end

    assert_equal 7, player[:shown]
  end

  def test_a_field_of_a_sprite_or_pool_is_set_like_a_variable
    player = played(frames: 1) do
      screen :tiled
      image(:hero, "#" => :red) { (["########"] * 8).join("\n") }
      hero = sprite :hero, at: [10, 20]
      shown = 0
      game_loop do
        hero.x = 30
        hero.y += 5
        shown = hero.x + hero.y
      end
    end

    assert_equal 55, player[:shown]
  end

  def test_a_list_slot_is_set_as_it_always_was
    player = played(frames: 1) do
      things = list :things, capacity: 2, full_of: 0
      shown = 0
      game_loop do
        things[0] = 3
        things[0] += 1
        shown = things[0]
      end
    end

    assert_equal 4, player[:shown]
  end

  def test_a_number_changed_inside_a_pools_each_in_the_game_loop_is_a_variable
    player = played(frames: 1) do
      sparks = pool(:spark, x: 0, capacity: 3)
      count = 0
      game_loop do
        sparks.spawn(x: 1)
        sparks.spawn(x: 2)
        sparks.each { count += 1 }
      end
    end

    assert_equal 2, player[:count]
  end

  def test_a_number_changed_by_a_menu_row_is_a_variable
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      picked = 0
      game_loop { menu(:main, at: [40, 40], press: :a) { |rows| rows.item("GO") { picked = 7 } } }
    end))
    builder.finalize_program
    player = game_player
    player.hold(:a)
    player.run(builder.program, frames: 3)

    assert_equal 7, player[:picked]
  end

  def test_a_block_a_test_hands_to_instance_exec_is_read_as_normal_ruby
    extra = proc { |hp| hp.increase! 1 if hp == 0 }
    builder = Builder.new
    builder.instance_eval do
      hp = var :hp, 0
      game_loop { instance_exec(hp, &extra) }
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)

    assert_equal 1, player[:hp]
  end

  def test_a_lambda_a_test_hands_to_instance_exec_is_read_as_normal_ruby
    extra = ->(hp) { hp.increase! 1 if hp == 0 }
    builder = Builder.new
    builder.instance_eval do
      hp = var :hp, 0
      game_loop { instance_exec(hp, &extra) }
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)

    assert_equal 1, player[:hp]
  end

  def test_bit_operators_join_tests_as_ruby_does_on_true_and_false
    player = played do
      a = var :a, 5
      both = 0
      neither = 0
      either = 0
      one = 0
      game_loop do
        both = 1 if (a > 1) & (a < 9)
        neither = 1 if (a > 1) & (a > 9)
        either = 1 if (a > 9) | (a > 1)
        one = 1 if (a > 1) ^ (a > 9)
      end
    end

    assert_equal [1, 0, 1, 1], %i[both neither either one].map { |name| player[name] }
  end

  def test_a_bit_operator_works_out_both_sides
    player = played do
      a = var :a, 5
      n = 0
      seen = 0
      game_loop { seen = 1 if (a > 9) & ((n += 1) > 0) }
    end

    assert_equal 0, player[:seen]
    assert_equal 3, player[:n]
  end

  def test_a_bit_operator_beside_a_plain_true_or_false_leaves_the_test
    player = played do
      a = var :a, 5
      yes = true
      no = false
      kept = 0
      dropped = 0
      given = 0
      number = 0
      game_loop do
        kept = 1 if yes & (a > 1)
        dropped = 1 if no & (a > 1)
        given = 1 if no | (a > 1)
        number = 1 if (a > 1) & a
      end
    end

    assert_equal [1, 0, 1, 1], %i[kept dropped given number].map { |name| player[name] }
  end

  def test_bit_assignment_changes_a_yes_or_no
    player = played do
      a = var :a, 5
      lost = true
      held = true
      game_loop do
        lost &= a > 9
        held &= a > 1
      end
    end

    assert_equal [0, 1], [player[:lost], player[:held]]
  end

  def test_a_number_given_to_a_methods_argument_leaves_the_caller_alone
    player = played do
      def set_to_nine(hp)
        hp = 9
        hp
      end
      hp = var :hp, 0
      seen = 0
      game_loop do
        seen = set_to_nine(hp)
      end
    end

    assert_equal [0, 9], [player[:hp], player[:seen]]
  end

  def test_adding_to_a_methods_argument_leaves_the_caller_alone
    player = played do
      def plus_ten(hp)
        hp += 10
        hp
      end
      hp = var :hp, 5
      seen = 0
      game_loop do
        seen = plus_ten(hp)
      end
    end

    assert_equal [5, 15], [player[:hp], player[:seen]]
  end

  def test_a_number_given_to_a_name_taken_from_a_hash_leaves_the_hash_alone
    player = played do
      ball = { hp: var(:hp, 5) }
      seen = 0
      game_loop do
        hp = ball[:hp]
        hp = 2
        seen = hp
      end
    end

    assert_equal [5, 2], [player[:hp], player[:seen]]
  end

  def test_adding_to_a_name_taken_from_a_hash_leaves_the_hash_alone
    player = played do
      ball = { hx: var(:hx, 5) }
      seen = 0
      game_loop do
        nx = ball[:hx]
        nx += 10
        seen = nx
      end
    end

    assert_equal [5, 15], [player[:hx], player[:seen]]
  end

  def test_a_name_started_from_another_local_is_a_game_variable
    player = played do
      start = 10
      x = start
      game_loop { x += 1 }
    end

    assert_equal 13, player[:x]
  end

  SIZES = [4, 8].freeze

  def test_a_name_started_from_a_method_or_a_list_is_a_game_variable
    player = played do
      def worked_out_start = 20
      from_method = worked_out_start
      from_list = SIZES[1]
      half = screen_width / 2
      game_loop do
        from_method += 1
        from_list += 1
        half += 1
      end
    end

    assert_equal [23, 11, 123], [player[:from_method], player[:from_list], player[:half]]
  end

  def test_a_start_with_an_effect_runs_once
    player = played do
      count = [0]
      def next_start(count) = count[0] += 1
      x = next_start(count)
      runs = count[0]
      seen = 0
      game_loop do
        x += 1
        seen = runs
      end
    end

    assert_equal [4, 1], [player[:x], player[:seen]]
  end

  def test_a_name_started_from_a_variable_and_changed_is_its_own_variable
    player = played do
      hp = var :hp, 5
      other = hp
      game_loop { other += 1 }
    end

    assert_equal [5, 8], [player[:hp], player[:other]]
  end

  def test_a_name_started_from_a_test_and_changed_keeps_a_yes_or_no
    player = played do
      hp = var :hp, 5
      alive = hp > 0
      seen = 0
      game_loop do
        alive = false
        seen = 1 if alive
      end
    end

    assert_equal 0, player[:seen]
  end

  # `if by` on an option asks what Ruby asks, whether it was given, even when what was given is a
  # game variable holding 0.
  def test_an_option_in_an_if_asks_whether_it_was_given
    player = played(frames: 2) do
      def count_if_given(tally, key, by: nil)
        tally[key] += 1 if by
      end
      zero = var :zero, 0
      tally = { given: var(:given, 0), left_out: var(:left_out, 0) }
      game_loop do
        count_if_given(tally, :given, by: zero)
        count_if_given(tally, :left_out)
      end
    end

    assert_operator player[:given], :>=, 1
    assert_equal 0, player[:left_out]
  end

  def test_a_number_added_up_over_a_list_written_out_in_ruby_stays_a_number
    player = played(frames: 2) do
      shown = 0
      game_loop do
        total = 0
        [1, 2, 3].each { |each_number| total += each_number }
        shown = total
      end
    end

    assert_equal 6, player[:shown]
  end

  def test_a_number_changed_under_a_game_test_inside_ruby_iteration_is_a_variable
    player = played(frames: 1) do
      n = 2
      hits = 0
      game_loop do
        [1, 2, 3].each { |each_number| hits += 1 if n == each_number }
      end
    end

    assert_equal 1, player[:hits]
  end

  def test_a_list_slot_at_a_fixed_place_can_stand_on_the_right_of_and
    player = played(frames: 1) do
      things = list :things, capacity: 2, full_of: 1
      n = 3
      found = 0
      game_loop do
        found = 1 if n == 3 && things[1] == 1
      end
    end

    assert_equal 1, player[:found]
  end

  def test_a_list_read_with_an_index_the_left_side_did_not_test_is_allowed
    player = played(frames: 1) do
      things = list :things, capacity: 2, full_of: 1
      i = 1
      n = 3
      found = 0
      game_loop do
        found = 1 if n == 3 && things[i] == 1
        i = 1
      end
    end

    assert_equal 1, player[:found]
  end

  def test_a_call_without_parentheses_can_be_assigned_to_a_name_set_before
    player = played(frames: 1) do
      shown = 0
      numbers = nil
      numbers = Array.new 2 do |each_slot| each_slot + 4 end
      total = 0
      total += numbers.sum do |each_number| each_number end
      game_loop { shown = total }
    end

    assert_equal 9, player[:shown]
  end

  def test_a_game_part_keeps_its_frozen_strings_and_its_line_numbers
    assert_predicate PlainRubyHelperPart::NAME, :frozen?
    assert_equal 8, PlainRubyHelperPart::WRITTEN_ON
  end

  def test_a_game_part_in_a_file_of_its_own_can_be_written_in_normal_ruby
    player = played(frames: 5, allow: %w[PlainRubyHelperPart]) do
      part = PlainRubyHelperPart.new(self)
      game_loop { part.step }
    end

    assert_equal 3, player[:part_count]
    assert_equal 9, player[:part_flips]
  end

  def test_assignment_changes_a_variable_made_with_var
    player = played(frames: 2) do
      hp = var :hp, 5
      game_loop { hp = hp + 1 }
    end

    assert_operator player[:hp], :>, 5
  end

  def test_a_second_name_for_a_variable_can_move_to_another
    player = played(frames: 1) do
      hero_x = var :hero_x, 1
      enemy_x = var :enemy_x, 2
      target = hero_x
      target = enemy_x
      shown = 0
      game_loop { shown = target }
    end

    assert_equal 2, player[:shown]
    assert_equal 1, player[:hero_x]
  end

  def test_a_picked_value_is_worked_out_at_its_line_on_every_pass
    player = played(frames: 3) do
      n = 0
      first = 0
      other = 0
      game_loop do
        x = n == 0 ? 10 : 20
        y = if n == 0 then 1 elsif n == 1 then 2 else 3 end
        first = x + y if n == 0
        other = x + y if n == 1
        n += 1
      end
    end

    assert_equal [11, 22], [player[:first], player[:other]]
  end

  def test_a_picked_value_keeps_its_answer_after_the_test_changes
    player = played(frames: 1) do
      n = 0
      shown = 0
      game_loop do
        x = n == 0 ? 10 : 20
        n = 5
        shown = x
      end
    end

    assert_equal 10, player[:shown]
  end

  def test_a_copy_made_while_playing_keeps_the_old_value
    player = played(frames: 1) do
      hp = 5
      old = 0
      game_loop do
        before = hp
        hp = 3
        old = before
      end
    end

    assert_equal [3, 5], [player[:hp], player[:old]]
  end

  def test_a_name_set_in_the_game_loop_starts_afresh_each_pass
    player = played(frames: 4) do
      shown = 0
      game_loop do
        count = 0
        count += 1
        shown = count
      end
    end

    assert_equal 1, player[:shown]
  end

  def test_the_same_name_in_two_routines_is_two_variables
    player = played(frames: 1) do
      shown = 0
      func(:one) { x = 1; x += 1; shown += x }
      func(:two) { x = 10; x += 1; shown += x }
      game_loop do
        shown = 0
        call :one
        call :two
      end
    end

    assert_equal 13, player[:shown]
  end

  # `3.times` runs while building, inside a side of a test the game makes: the side adds three
  # when the test holds, and the name keeps its start when it does not.
  def test_a_number_changed_in_a_ruby_block_under_a_game_test_follows_the_test
    game = proc do
      def counted(a)
        n = 0
        if a > 3
          3.times { n += 1 }
        end
        n
      end
      hp = 5
      seen = 0
      game_loop do
        seen = counted(hp)
        hp -= 3
      end
    end

    assert_equal 3, played(frames: 1, &game)[:seen]
    assert_equal 0, played(frames: 2, &game)[:seen]
  end

  # `tap` and an `each` on a list held in a name may be a pool's, so only running them can tell
  # whether they record game code: the name starts again on each call either way.
  def test_a_number_changed_in_any_block_under_a_game_test_in_a_method_follows_the_test
    game = proc do
      def counted(a)
        n = 0
        list = [1, 2, 3]
        if a > 3
          0.tap { n += 10 }
          list.each { |each_number| n += each_number }
        end
        n
      end
      hp = 5
      seen = 0
      game_loop do
        seen = counted(hp)
        hp -= 3
      end
    end

    assert_equal 16, played(frames: 1, &game)[:seen]
    assert_equal 0, played(frames: 2, &game)[:seen]
  end

  # A lambda runs where it is called. Called under a test the game makes, the number it changes
  # follows the test, as Ruby's would: one on the pass the test holds, none on the next.
  def test_a_number_a_lambda_changes_called_under_a_game_test_follows_the_test
    game = proc do
      def counted(a)
        n = 0
        bump = -> { n += 1 }
        bump.call if a > 3
        n
      end
      hp = 5
      seen = 0
      game_loop do
        seen = counted(hp)
        hp -= 3
      end
    end

    assert_equal 1, played(frames: 1, &game)[:seen]
    assert_equal 0, played(frames: 2, &game)[:seen]
  end

  # A method made from a block counts as one made with `def` does: the count starts again on each
  # call, and a pool's `each` under a game test adds one a thing.
  def test_a_number_counted_in_a_method_made_from_a_block_follows_the_test
    player = played do
      sparks = pool :sparks, x: 0, capacity: 3
      sparks.spawn(x: 1)
      sparks.spawn(x: 2)
      go = 1
      shown = 0
      define_singleton_method(:count_sparks) do
        t = 0
        if go == 1
          sparks.each { t += 1 }
        end
        shown = t
      end
      game_loop { count_sparks }
    end

    assert_equal 2, player[:shown]
  end

  # The same count in a lambda kept in a name and called from the game loop.
  def test_a_number_counted_in_a_lambda_the_game_loop_calls_follows_the_test
    player = played do
      sparks = pool :sparks, x: 0, capacity: 3
      sparks.spawn(x: 1)
      sparks.spawn(x: 2)
      go = 1
      shown = 0
      count_sparks = lambda do
        t = 0
        if go == 1
          sparks.each { t += 1 }
        end
        shown = t
      end
      game_loop { count_sparks.call }
    end

    assert_equal 2, player[:shown]
  end

  # A fraction a method made from a block starts and changes under a game test stays a fraction.
  def test_a_fraction_changed_in_a_method_made_from_a_block_follows_the_test
    game = proc do
      shown = 0.0
      define_singleton_method(:step_once) do
        x = 0.5
        x += 1 if shown == 0
        shown = x
      end
      game_loop { step_once }
    end

    assert_in_delta 1.5, played(frames: 1, &game)[:shown], 0.01
    assert_in_delta 0.5, played(frames: 2, &game)[:shown], 0.01
  end

  # The body runs once before the test is asked, whatever the test is.
  def test_a_number_changed_in_a_begin_while_on_a_game_test_goes_round_as_ruby_does
    game = proc do
      def counted(limit)
        n = 0
        begin
          n += 1
        end while n < limit
        n
      end
      limit = 3
      seen = 0
      game_loop do
        seen = counted(limit)
        limit = 0
      end
    end

    assert_equal 3, played(frames: 1, &game)[:seen]
    assert_equal 1, played(frames: 2, &game)[:seen]
  end

  # A pool's `each` records code the game runs, here once as it starts.
  def test_a_number_counted_by_a_pools_each_while_setting_up_is_a_variable
    player = played(frames: 1) do
      sparks = pool(:spark, x: 0, capacity: 3)
      sparks.spawn(x: 1)
      sparks.spawn(x: 2)
      count = 0
      sparks.each { count += 1 }
      shown = 0
      game_loop { shown = count }
    end

    assert_equal 2, player[:shown]
  end

  # `each` on a list held in a name is Ruby's while setting up, so the count is a Ruby number
  # the build can use: here as the width of a shift, which a game number cannot be.
  def test_a_number_counted_by_a_ruby_lists_each_while_setting_up_stays_a_ruby_number
    player = played(frames: 1) do
      counted = 0
      names = %i[a b c]
      names.each { counted += 1 }
      wide = 1 << counted
      shown = 0
      game_loop { shown = wide }
    end

    assert_equal 8, player[:shown]
  end

  # Ruby asks the left side of `==`, and a plain 3 asked about a game number answers for itself.
  # The test is the game's whichever side the plain number is on.
  def test_a_plain_number_on_the_left_of_an_equality_is_a_test_the_game_makes
    player = played(frames: 5) do
      hp = 0
      same = 0
      different = 0
      state = :title
      titles = 0
      game_loop do
        same += 1 if 3 == hp
        different += 1 if 3 != hp
        titles += 1 if :title == state
        state = :playing
        hp += 1
      end
    end

    assert_equal 1, player[:same], "hp is 3 on one pass"
    assert_equal player[:hp] - 1, player[:different]
    assert_equal 1, player[:titles]
  end

  # `until row == rows` with row a plain 0 when the loop is reached: the loop is the game's.
  def test_a_loop_until_a_plain_counter_equals_a_game_number_goes_round
    player = played(frames: 1) do
      rows = var :rows, 4
      row = 0
      until row == rows
        row += 1
      end
      rounds = var :rounds, 0
      rounds.store!(row)
      game_loop { wait_vblank }
    end

    assert_equal 4, player[:rounds]
  end

  def test_two_names_started_on_one_line_in_game_code_start_afresh_on_every_pass
    player = played(frames: 3) do
      most = 0
      game_loop do
        count, other = 0, 1
        repeat(3) { count += other }
        most = count if count > most
      end
    end

    assert_equal 3, player[:most]
  end

  # `column = 0` at the top of each round of a loop the game makes, counted by a loop of Ruby's
  # inside it: the counter is plain Ruby, written out twice, on every round.
  def test_a_ruby_loop_counted_from_zero_inside_a_loop_of_the_games_is_written_out
    player = played(frames: 1) do
      rows = var :rows, 3
      cells = var :cells, 0
      row = var :row, 0
      while row < rows
        column = 0
        while column < 2
          cells += 1
          column += 1
        end
        row += 1
      end
      game_loop { wait_vblank }
    end

    assert_equal 6, player[:cells]
  end

  # `@shown` holds whichever number it was last given, as a Ruby name would.
  def test_an_instance_variable_moved_to_another_number_in_game_code_takes_that_number
    game = proc do
      score = 5
      lives = 3
      @shown = score
      game_loop do
        @shown = lives
        lives -= 1
        score += 1
      end
    end

    assert_equal 3, played(frames: 1, &game)[:shown]
    assert_equal 2, played(frames: 2, &game)[:shown]
  end

  # The game's own instance variables are named in its block, as a part's are in its class.
  def test_the_games_own_named_instance_variable_counts_as_the_game_plays
    player = played(frames: 4) do
      game_variables :score
      @score = 0
      seen = var :seen, 0
      game_loop do
        @score += 1
        seen.store!(@score)
      end
    end

    assert_equal 4, player[:seen]
  end

  # Given a name of the game's own, and copied from another of its named values on every pass.
  def test_the_games_own_named_instance_variable_is_read_by_the_name_it_was_given
    player = played(frames: 3) do
      game_variables :score, best: :best_score
      @score = 0
      @best = 0
      game_loop do
        @score += 2
        @best = @score
      end
    end

    assert_equal [6, 6], [player[:score], player[:best_score]]
  end

  def test_two_named_instance_variables_given_one_variable_name_are_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played { game_variables score: :points, best: :points }
    end

    assert_match(/`@score` and `@best` the same variable name/, error.message)
  end

  def test_saved_given_something_but_true_or_false_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played { game_variables :score, saved: :points }
    end

    assert_match(/takes `saved: false` or `saved: true`/, error.message)
    assert_match(/game_variables\(\{ saved: :points \}\)/, error.message)
  end

  def test_the_games_own_unnamed_instance_variable_counted_then_read_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        @score = 0
        seen = var :seen, 0
        game_loop do
          @score += 1
          seen.store!(@score)
        end
      end
    end

    assert_match(/game_variables :score` to the game block/, error.message)
  end
end
