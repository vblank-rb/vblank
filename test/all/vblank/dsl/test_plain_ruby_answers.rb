# frozen_string_literal: true

require "test_helper"
require "ruby_answers"

VBlank.require_game_file "../../../ruby_answers_parts"

# Plain Ruby game code held to Ruby's own answers (RubyAnswers, test/ruby_answers.rb): each case
# runs as plain Ruby and as the game, on every lowering, and the names it reads must agree. A
# known gap says what the open work on it is called, and fails once the game agrees.
#
# Add a case here for every new plain-Ruby form, and for every wrong answer a review finds.
class TestPlainRubyAnswers < Minitest::Test
  include RubyAnswers

  # --- passes ---

  def test_passes_count_alike
    agrees("passes", reads: %i[n], passes: 3) do
      n = 0
      game_loop { n += 1 }
    end
  end

  # --- numbers ---

  def test_max_and_min_of_game_numbers
    agrees("[a, b].max and min", reads: %i[m n o p]) do
      a = 3
      b = 7
      m = n = o = p = 0
      game_loop do
        a += 1 if pressed(:a)
        b += 1 if pressed(:b)
        m = [a, b].max
        n = [b, a].max
        o = [a, b].min
        p = [b, a].min
      end
    end
  end

  def test_clamp_and_abs
    agrees("clamp and abs", reads: %i[m n]) do
      a = 3
      m = n = 0
      game_loop do
        a += 1 if pressed(:a)
        m = a.clamp(4, 10)
        n = (a - 9).abs
      end
    end
  end

  def test_range_and_list_tests
    agrees("include? and case on a range", reads: %i[m n o]) do
      a = 3
      m = n = o = 0
      game_loop do
        a += 1 if pressed(:a)
        m = (0..4).include?(a) ? 1 : 2
        n = [1, 3].include?(a) ? 1 : 2
        case a
        when 0..2 then o = 1
        else o = 2
        end
      end
    end
  end

  def test_tests_on_a_number
    agrees("positive? and zero? as tests", reads: %i[m n o]) do
      a = 3
      m = n = o = 0
      game_loop do
        a += 1 if pressed(:a)
        m = a.positive? ? 1 : 2
        n = a.zero? ? 1 : 0
        o = a.even? ? 1 : 2
      end
    end
  end

  def test_counted_loops_over_game_numbers
    agrees("upto, times and for over a game number", reads: %i[m n o]) do
      a = 3
      m = n = o = 0
      game_loop do
        a += 1 if pressed(:a)
        m = 0
        0.upto(a) { m += 1 }
        n = 0
        a.times { |i| n += i }
        o = 0
        for i in 0...a
          o += i
        end
      end
    end
  end

  # A known count whose rounds are large: the build makes them one loop.
  def test_a_large_known_count_made_a_loop
    agrees("16.times, 2.upto(17), (0...16).each and for with large bodies", reads: %i[m n o p], passes: 3) do
      a = 1
      m = n = o = p = 0
      game_loop do
        a += 1 if pressed(:a)
        m = n = o = p = 0
        16.times do |i|
          m += (i * 3) + a
          m -= i - 2
          m += 1
        end
        2.upto(17) do |i|
          n += (i * a) - 4
          n -= i
          n += 7
        end
        (0...16).each do |i|
          o -= i * 2
          o += a
          o += i
        end
        for i in 0..15
          p += (i * i) + a
          p -= 1
          p += 1
        end
      end
    end
  end

  # A known count whose rounds are small, and one whose rounds differ beyond a number counted up:
  # each is written out.
  def test_known_counts_written_out
    agrees("4.times small, and 16.times reading a table while building", reads: %i[m n]) do
      table = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3]
      a = 1
      m = n = 0
      game_loop do
        a += 1 if pressed(:a)
        m = n = 0
        4.times { |i| m += i + a }
        16.times do |i|
          n += table[i] + a
          n -= 1
          n += 1
        end
      end
    end
  end

  # A known count inside a known count, each large enough to be a loop.
  def test_a_known_count_inside_a_known_count
    agrees("8.times around 16.times", reads: %i[m]) do
      a = 1
      m = 0
      game_loop do
        a += 1 if pressed(:a)
        m = 0
        8.times do |row|
          16.times do |column|
            m += (row * 100) + column
            m -= a
            m += a
          end
        end
      end
    end
  end

  # --- instance variables game code changes ---

  def test_an_instance_variable_switched_on_one_line
    agrees("@lit = 1 - @lit", reads: %i[n], passes: 3) do
      lamp = AnswerLamp.new
      n = 0
      game_loop do
        lamp.switch
        n = lamp.lit
      end
    end
  end

  def test_an_instance_variable_switched_by_a_routine
    agrees("@lit switched in a func its part made", reads: %i[n], passes: 3) do
      lamp = AnswerRoutineLamp.new(self)
      n = 0
      game_loop do
        call :switch_answer_lamp
        n = lamp.lit
      end
    end
  end

  def test_an_instance_variable_read_before_it_is_changed
    agrees("@ticks read in one method before another changes it", reads: %i[a b], passes: 3) do
      ticker = AnswerTicker.new
      ticker.grow!
      a = b = 0
      game_loop do
        a = ticker.shown
        ticker.tick
        b = Array.new(ticker.size, 1).sum
      end
    end
  end

  def test_a_flag_tested_around_game_code_then_toggled
    agrees("@seen += 1 if @open, then @open = !@open", reads: %i[s], passes: 3) do
      door = AnswerRoutineDoor.new(self)
      s = 0
      game_loop do
        call :answer_door_tick
        s = door.seen
      end
    end
  end

  # A flag toggled from what it holds (`@open = !@open`) is one its class may change, so it is the
  # game's wherever game code first tests it: through a method, or to pick a number.
  def test_a_flag_tested_through_a_method_before_it_is_changed
    agrees("s += 1 if door.open?, then toggled", reads: %i[s], passes: 3) do
      door = AnswerDoor.new
      s = 0
      game_loop do
        s += 1 if door.open?
        door.toggle
      end
    end
  end

  def test_a_flag_tested_for_a_number_before_it_is_changed
    agrees("@open tested for a number, then toggled", reads: %i[s], passes: 2) do
      door = AnswerDoor.new
      s = 0
      game_loop do
        s = door.seen
        door.toggle
      end
    end
  end

  # A flag a method sets outright (`def open! = @open = true`) is not marked by the source, so a
  # test on it through a reader, or one picking a number, would be decided while building. The
  # build stops at the end, naming the fix.
  def test_a_flag_set_in_a_method_and_tested_through_a_reader_is_refused
    refused("s += 1 if latch.open?, then latch.open!", /game_variables :open/) do
      latch = AnswerLatch.new
      s = 0
      game_loop do
        s += 1 if latch.open?
        latch.open!
      end
    end
  end

  def test_a_flag_set_in_a_method_and_tested_for_a_number_is_refused
    refused("s = latch.seen, then latch.open!", /game_variables :open/) do
      latch = AnswerLatch.new
      s = 0
      game_loop do
        s = latch.seen
        latch.open!
      end
    end
  end

  # A once-guard asked through a reader guards building work, not game code: left to Ruby.
  def test_a_once_guard_asked_through_a_reader
    agrees("plan unless planned?", reads: %i[n], passes: 3) do
      planner = AnswerPlanner.new(self)
      n = 0
      game_loop do
        planner.step
        n = planner.steps
      end
    end
  end

  def test_two_objects_of_one_class
    agrees("one lamp switched, one left", reads: %i[x y], passes: 3) do
      one = AnswerLamp.new
      other = AnswerLamp.new
      x = y = 0
      game_loop do
        one.switch
        x = one.lit
        y = other.lit
      end
    end
  end

  def test_an_instance_variable_changed_through_its_writer
    agrees("dial.level = dial.level + 3", reads: %i[m], passes: 3) do
      dial = AnswerDial.new
      m = 0
      game_loop do
        m = dial.level
        dial.level = dial.level + 3
      end
    end
  end

  def test_a_hash_instance_variable_counted_at_known_keys
    agrees("@counters[side] += 1", reads: %i[n], passes: 3) do
      tally = AnswerTally.new
      n = 0
      game_loop do
        tally.count
        n = tally.left
      end
    end
  end

  def test_an_array_instance_variable_counted_at_a_worked_out_index
    agrees("@counts[at] += 1", reads: %i[n], passes: 3) do
      slots = AnswerSlots.new
      at = 2
      n = 0
      game_loop do
        at = (at + 1) % 3
        slots.bump(at)
        n = slots.first
      end
    end
  end

  def test_a_named_array_changed_through_its_reader_by_another_part
    agrees("@tallies.counts[at] += 1, counts named", reads: %i[n m], passes: 4) do
      keeper = AnswerTallyKeeper.new(AnswerNamedTallies.new)
      at = 2
      n = m = 0
      game_loop do
        at = (at + 1) % 3
        keeper.bump(at)
        n = keeper.first
        m = keeper.bump(1)
      end
    end
  end

  def test_an_array_changed_through_its_reader_by_another_part
    agrees("@tallies.counts[at] += 1", reads: %i[n m], passes: 4) do
      keeper = AnswerTallyKeeper.new(AnswerTallies.new)
      at = 2
      n = m = 0
      game_loop do
        at = (at + 1) % 3
        keeper.bump(at)
        n = keeper.first
        m = keeper.bump(1)
      end
    end
  end

  def test_an_array_changed_through_its_reader_in_the_game_block
    agrees("tallies.counts[at] += 1", reads: %i[n m], passes: 4) do
      tallies = AnswerTallies.new
      at = 2
      n = m = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
        n = tallies.counts[0]
        m = tallies.counts[at]
      end
    end
  end

  def test_an_array_read_through_its_reader_at_known_indexes
    agrees("marks.marks[0] += 1", reads: %i[n m], passes: 3) do
      marks = AnswerMarks.new
      n = m = 0
      game_loop do
        marks.marks[0] += 1
        marks.marks[1] += 2
        n = marks.marks[0]
        m = marks.marks[1]
      end
    end
  end

  def test_an_array_from_a_reader_put_in_a_local_then_read_at_a_worked_out_index_is_refused
    refused("marks = m.marks; marks[at]", /`part\.counts\[at\]`/) do
      holder = AnswerMarks.new
      at = 0
      n = 0
      game_loop do
        at = 1 - at
        marks = holder.marks
        n = marks[at]
      end
    end
  end

  def test_a_copy_from_a_method_named_as_a_reader_changed_at_a_worked_out_index_is_refused
    refused("c.counts[at] += 1, counts a copy", /does not keep/) do
      copied = AnswerCopiedTallies.new(0)
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        copied.counts[at] += 1
        n = copied.first
      end
    end
  end

  def test_a_copy_of_fractions_from_a_method_named_as_a_reader_is_refused
    refused("c.counts[at] += 1, counts a copy of fractions", /does not keep/) do
      copied = AnswerCopiedTallies.new(0.5)
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        copied.counts[at] += 1
        n = (copied.first * 2).to_i
      end
    end
  end

  def test_one_array_shared_by_two_parts_through_a_reader_is_refused
    refused("p1.counts[at] += 1, p2.counts[at], one Array", /same Array/) do
      shared = [0, 0, 0]
      one = AnswerSharedTallies.new(shared)
      other = AnswerSharedTallies.new(shared)
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        one.counts[at] += 1
        n = other.counts[at]
      end
    end
  end

  def test_one_array_shared_by_two_parts_of_one_class_is_refused
    refused("p1.bump(at), p2.at(at), one Array", /same Array/) do
      shared = [0, 0, 0]
      one = AnswerSharedTallies.new(shared)
      other = AnswerSharedTallies.new(shared)
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        one.bump(at)
        n = other.at(at)
      end
    end
  end

  def test_the_answer_of_a_changed_item
    agrees("m = (counts[at] += 1)", reads: %i[m], passes: 3) do
      counts = [0, 4, 0]
      at = 0
      m = 0
      game_loop do
        at = (at + 1) % 3
        m = (counts[at] += 1)
      end
    end
  end

  def test_an_array_changed_through_its_reader_at_known_indexes
    agrees("board.scores[1] += 2", reads: %i[n m], passes: 3) do
      board = AnswerScores.new
      n = m = 0
      game_loop do
        board.scores[1] += 2
        board.scores[0] -= 1
        n = board.scores[0]
        m = board.scores[1]
      end
    end
  end

  def test_a_struct_field_game_code_changes
    agrees("point.x += 1 on a Struct kept in a local", reads: %i[n], passes: 3) do
      point = AnswerPoint.new(1, 2, 0)
      n = 0
      game_loop do
        point.x += 1
        n = point.x
      end
    end
  end

  def test_a_struct_field_read_before_game_code_changes_it
    agrees("n = point.x, then point.x += 1", reads: %i[n], passes: 3) do
      point = AnswerPoint.new(1, 2, 0)
      n = 0
      game_loop do
        n = point.x
        point.x += 1
      end
    end
  end

  def test_a_struct_field_set_outright_in_an_instance_variable
    agrees("@point.y = @point.y + 2", reads: %i[n m], passes: 3) do
      @point = AnswerPoint.new(1, 2, 0)
      n = m = 0
      game_loop do
        @point.y = @point.y + 2
        n = @point.y
        m = @point.x
      end
    end
  end

  def test_a_struct_kept_with_or_equals_in_the_game_loop
    agrees("@point ||= AnswerPoint.new in game_loop, @point.x += 1", reads: %i[n], passes: 3) do
      n = 0
      game_loop do
        @point ||= AnswerPoint.new(1, 2, 0)
        @point.x += 1
        n = @point.x
      end
    end
  end

  # Ruby makes it on the first pass alone and keeps changing that one.
  def test_a_struct_made_under_a_test_and_used_after_it_is_refused
    refused("@point = AnswerPoint.new on the first pass, @point.x += 1", /under an `if`.*above the game loop/m) do
      n = started = 0
      game_loop do
        if started == 0
          @point = AnswerPoint.new(1, 2, 0)
          started = 1
        end
        @point.x += 1
        n = @point.x
      end
    end
  end

  def test_a_struct_made_in_the_game_loop_and_used_in_a_routine_is_refused
    refused("@point = AnswerPoint.new on the first pass, @point.x read in a func", /another.*`func`/m) do
      n = started = 0
      func(:answer_reads_point) { n = @point.x }
      game_loop do
        if started == 0
          @point = AnswerPoint.new(1, 2, 0)
          started = 1
        end
        call :answer_reads_point
      end
    end
  end

  # The func's lines are built after the loop's, so the loop's read finds nothing yet.
  def test_an_instance_variable_a_func_sets_read_in_the_game_loop_is_refused
    refused("func sets @point, game_loop reads it", /`@point`.*above the game loop/m) do
      n = 0
      func(:answer_makes_point) { @point = AnswerPoint.new(1, 2, 0) }
      game_loop do
        call :answer_makes_point if n == 0
        @point.x += 1
        n = @point.x
      end
    end
  end

  def test_an_instance_variable_a_func_sets_given_a_value_above_the_game_loop
    agrees("@level above, a func sets it, game_loop reads it", reads: %i[n], passes: 3) do
      n = 0
      @level = 1
      func(:answer_raises_level) { @level += 2 }
      game_loop do
        call :answer_raises_level
        n = @level
      end
    end
  end

  # Made and used under one test, it is the one Ruby makes on that pass.
  def test_a_struct_made_and_used_under_one_test
    agrees("AnswerPoint made and read under one if", reads: %i[n], passes: 3) do
      n = passes = 0
      game_loop do
        passes += 1
        if passes > 1
          point = AnswerPoint.new(passes, 0, 0)
          point.x += 10
          n = point.x
        end
      end
    end
  end

  # A Struct made in the loop is new on every pass, in Ruby too, beside one that lives on.
  def test_a_struct_made_in_the_game_loop_beside_one_kept
    agrees("fresh AnswerPoint in game_loop beside a kept one", reads: %i[n m], passes: 3) do
      kept = AnswerPoint.new(1, 2, 0)
      n = m = 0
      game_loop do
        n = kept.x
        fresh = AnswerPoint.new(5, 0, 0)
        fresh.x += 1
        m = fresh.x
        kept.x += fresh.x
      end
    end
  end

  # A Struct made while setting up from a number game code changes holds a copy of it.
  def test_a_struct_made_from_a_changing_number_keeps_a_copy
    agrees("AnswerPoint.new(score, 0, 0), then score += 1 and point.x += 10", reads: %i[n m], passes: 3) do
      score = 0
      point = AnswerPoint.new(score, 0, 0)
      n = m = 0
      game_loop do
        score += 1
        point.x += 10
        n = point.x
        m = score
      end
    end
  end

  def test_two_structs_made_from_one_number_keep_a_copy_each
    agrees("two AnswerPoints made from one number", reads: %i[n m], passes: 3) do
      start = 0
      a = AnswerPoint.new(start, 0, 0)
      b = AnswerPoint.new(start, 0, 0)
      n = m = 0
      game_loop do
        start += 0
        a.x += 1
        b.x += 5
        n = a.x
        m = b.x
      end
    end
  end

  # A Struct made in the loop from a game number holds the number it had there.
  def test_a_struct_made_in_the_game_loop_from_a_number_changed_after
    agrees("fresh = AnswerPoint.new(passes, 0, 0); passes += 5", reads: %i[n], passes: 3) do
      n = passes = 0
      game_loop do
        passes += 1
        fresh = AnswerPoint.new(passes, 0, 0)
        passes += 5
        n = fresh.x
      end
    end
  end

  def test_a_field_of_a_struct_made_in_the_game_loop_set_from_a_number_changed_after
    agrees("fresh.x = passes; passes += 5", reads: %i[n], passes: 3) do
      n = passes = 0
      game_loop do
        passes += 1
        fresh = AnswerPoint.new(0, 0, 0)
        fresh.x = passes
        passes += 5
        n = fresh.x
      end
    end
  end

  def test_a_field_of_a_struct_made_in_the_game_loop_set_from_a_kept_field
    agrees("fresh.x = kept.x; fresh.x += 10; kept.x += 1", reads: %i[n m], passes: 3) do
      kept = AnswerPoint.new(1, 0, 0)
      n = m = 0
      game_loop do
        fresh = AnswerPoint.new(0, 0, 0)
        fresh.x = kept.x
        fresh.x += 10
        kept.x += 1
        n = kept.x
        m = fresh.x
      end
    end
  end

  def test_a_field_of_a_struct_made_in_the_game_loop_set_under_a_game_test
    agrees("fresh.x = passes if passes == 2", reads: %i[n], passes: 3) do
      n = passes = 0
      game_loop do
        passes += 1
        fresh = AnswerPoint.new(0, 0, 0)
        fresh.x = passes if passes == 2
        n = fresh.x
      end
    end
  end

  def test_a_struct_field_read_by_its_key_before_game_code_changes_it
    agrees("n = point[:x], then point.x += 1", reads: %i[n], passes: 3) do
      point = AnswerPoint.new(1, 0, 0)
      n = 0
      game_loop do
        n = point[:x]
        point.x += 1
      end
    end
  end

  # Ruby makes a new one on every pass, after the read: each pass after the first reads the one the
  # pass before made, which the game cannot follow.
  def test_a_struct_replaced_on_every_pass_after_it_is_read_is_refused
    refused("n = point.x; point = AnswerPoint.new(100, 0, 0); point.x += 1", /new `AnswerPoint`.*change its fields/m) do
      point = AnswerPoint.new(1, 0, 0)
      n = 0
      game_loop do
        n = point.x
        point = AnswerPoint.new(100, 0, 0)
        point.x += 1
      end
    end
  end

  # Read only after the line that gives it a new one, each pass reads its own.
  def test_a_struct_replaced_on_every_pass_before_it_is_read
    agrees("point = AnswerPoint.new(100, 0, 0); point.x += 1; n = point.x", reads: %i[n], passes: 3) do
      point = AnswerPoint.new(1, 0, 0)
      n = 0
      game_loop do
        point = AnswerPoint.new(100, 0, 0)
        point.x += 1
        n = point.x
      end
    end
  end

  def test_a_struct_read_whole_with_to_a
    agrees("point.x += 1; n = point.to_a.first", reads: %i[n], passes: 3) do
      point = AnswerPoint.new(1, 0, 0)
      n = 0
      game_loop do
        point.x += 1
        n = point.to_a.first
      end
    end
  end

  # Ruby works out the right side whole before it gives any field a number.
  def test_two_fields_swapped
    agrees("point.x, point.y = point.y, point.x", reads: %i[n m], passes: 3) do
      point = AnswerPoint.new(1, 2, 0)
      n = m = 0
      game_loop do
        point.x, point.y = point.y, point.x
        point.x += 10
        n = point.x
        m = point.y
      end
    end
  end

  def test_fields_of_two_structs_swapped
    agrees("a.x, b.x = b.x, a.x", reads: %i[n m], passes: 3) do
      a = AnswerPoint.new(1, 0, 0)
      b = AnswerPoint.new(2, 0, 0)
      n = m = 0
      game_loop do
        a.x, b.x = b.x, a.x
        a.x += 10
        n = a.x
        m = b.x
      end
    end
  end

  # Every way Ruby reads a Struct's fields reads the number each field was given.
  def test_a_struct_made_from_a_changing_number_read_every_way
    agrees("pattern, dig, values_at, each, each_pair, sum, to_h", reads: %i[a b c d e f g], passes: 3) do
      score = 0
      points = Array.new(7) { AnswerPoint.new(score, 0, 0) } # one for each way, so none reads first for another
      a = b = c = d = e = f = g = 0
      game_loop do
        score += 1
        case points[0]
        in { x: } then a = x
        end
        case points[1]
        in [first, *] then b = first
        end
        c = points[2].dig(:x)
        d = points[3].values_at(0).first
        e = 0
        points[4].each { |field| e += field }
        f = 0
        points[5].each_pair { |_, field| f += field }
        g = points[6].sum
      end
    end
  end

  # A Data object keeps the number it was made from, as a Struct does.
  def test_a_data_object_made_from_a_changing_number_keeps_a_copy
    agrees("AnswerFixedPoint.new(x: score), then score += 1", reads: %i[n], passes: 3) do
      score = 0
      point = AnswerFixedPoint.new(x: score, y: 0)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  def test_a_data_object_made_in_the_game_loop_from_a_number_changed_after
    agrees("fresh = AnswerFixedPoint.new(x: score); score += 5", reads: %i[n], passes: 3) do
      score = 0
      n = 0
      game_loop do
        score += 1
        fresh = AnswerFixedPoint.new(x: score, y: 0)
        score += 5
        n = fresh.x
      end
    end
  end

  # A Data object cannot change, so a new one each pass is its only way to count.
  def test_a_data_object_made_again_with_with_is_refused
    refused("point = point.with(x: point.x + 1)", /Data class.*Struct/m) do
      point = AnswerFixedPoint.new(x: 1, y: 0)
      n = 0
      game_loop do
        point = point.with(x: point.x + 1)
        n = point.x
      end
    end
  end

  # Made on every pass and read in a routine the loop calls, which could be called from anywhere:
  # refused, in words true of the loop that makes it.
  def test_a_struct_made_in_the_game_loop_read_in_a_routine_is_refused
    refused("point made each pass, read in a func", /makes again on each pass.*in the game loop/m) do
      n = 0
      point = nil
      func(:answer_reads_fresh_point) { n = point.x }
      game_loop do
        point = AnswerPoint.new(7, 0, 0)
        call :answer_reads_fresh_point
      end
    end
  end

  def test_the_game_blocks_own_instance_variable
    agrees("@score += 2 in the game block", reads: %i[s], passes: 3) do
      @score = 0
      s = 0
      game_loop do
        s = @score
        @score += 2
      end
    end
  end

  def test_one_instance_variable_given_another_then_the_other_changed
    agrees("@a = @b, then @b += 1", reads: %i[x y], passes: 3) do
      pair = AnswerPair.new
      x = y = 0
      game_loop do
        pair.step
        x = pair.a
        y = pair.b
      end
    end
  end

  def test_an_instance_variable_set_back_under_a_test_the_game_makes
    agrees("@n = 0 if reset, then @n += 1", reads: %i[m], passes: 3) do
      counter = AnswerReset.new
      k = 0
      m = 0
      game_loop do
        k += 1
        counter.step(k == 100)
        m = counter.n
      end
    end
  end

  def test_an_instance_variable_set_back_in_a_routine_nothing_calls
    agrees("@n = 0 in a func never called, @n += 1 in the loop", reads: %i[m], passes: 3) do
      setter = AnswerSetter.new
      m = 0
      func(:answer_setter_reset) { setter.reset }
      game_loop do
        setter.step
        m = setter.n
      end
    end
  end

  # The set comes before the read in one routine, but under a test the game makes: Ruby's number
  # after it is the one only some passes give.
  def test_a_number_set_outright_by_its_own_method_under_a_game_test_then_read_is_refused
    refused("r.reset if k == 2, then m = r.n", /game_variables :n/) do
      r = AnswerResetOutright.new
      k = 0
      m = 0
      game_loop do
        k += 1
        r.reset if k == 2
        m = r.n
      end
    end
  end

  def test_a_number_read_then_set_outright_by_its_own_method_under_a_game_test_is_refused
    refused("m = r.n, then r.reset if k == 2", /game_variables :n/) do
      r = AnswerResetOutright.new
      k = 0
      m = 0
      game_loop do
        k += 1
        m = r.n
        r.reset if k == 2
      end
    end
  end

  # `@lives = nil` to start: the loop counting it down is read before the routine that gives it
  # its number.
  def test_lives_that_start_as_nothing_counted_down_before_their_number_is_refused
    refused("@lives -= 1 while @lives holds nil", /`@lives` holds `nil`/) do
      lives = AnswerLives.new
      m = 0
      k = 0
      func(:answer_lives_start) { lives.start }
      game_loop do
        k += 1
        call :answer_lives_start if k == 1
        lives.lose
        m = lives.lives
      end
    end
  end

  # ...and with the routine giving the number read first, in another routine than the count.
  def test_lives_given_a_number_in_one_routine_and_counted_in_another_are_refused
    refused("start in one func, lose and read in another", /game_variables :lives/) do
      lives = AnswerLives.new
      m = 0
      k = 0
      func(:answer_lives_begin) { lives.start }
      func(:answer_lives_tick) do
        lives.lose
        m = lives.lives
      end
      game_loop do
        k += 1
        call :answer_lives_begin if k == 1
        call :answer_lives_tick
      end
    end
  end

  # --- objects made in code that runs every frame ---

  # Ruby makes a fresh counter on every pass; the game would keep one.
  def test_a_changing_object_made_in_the_game_loop_is_refused
    refused("c = AnswerCounter.new in game_loop", /above the game loop/) do
      m = 0
      game_loop do
        c = AnswerCounter.new
        c.bump
        m = c.n
      end
    end
  end

  def test_a_changing_object_made_in_a_routine_is_refused
    refused("c = AnswerCounter.new in a func", /above the game loop/) do
      m = 0
      func(:answer_fresh_counter) do
        c = AnswerCounter.new
        c.bump
        m = c.n
      end
      game_loop { call :answer_fresh_counter }
    end
  end

  def test_a_changing_object_made_in_a_scene_is_refused
    refused("c = AnswerCounter.new in a scene", /above the game loop/) do
      m = 0
      scene(:answer_counting) do
        c = AnswerCounter.new
        c.bump
        m = c.n
      end
      game_loop { call :answer_counting }
    end
  end

  # An object made in a routine whose `initialize` makes an Array is made, and its Array filled,
  # again on every pass in Ruby.
  def test_an_object_filling_its_own_array_made_in_the_game_loop_is_refused
    refused("AnswerFilled.new in game_loop", /above the game loop/) do
      m = 0
      game_loop do
        filled = AnswerFilled.new
        m = filled.count
      end
    end
  end

  # `@counter ||= ...` makes it the first time the line runs and keeps it after, in Ruby too.
  def test_a_changing_object_kept_with_or_equals_in_the_game_loop
    agrees("@counter ||= AnswerCounter.new", reads: %i[m], passes: 3) do
      m = 0
      game_loop do
        @counter ||= AnswerCounter.new
        @counter.bump
        m = @counter.n
      end
    end
  end

  def test_an_object_that_never_changes_made_in_the_game_loop
    agrees("AnswerSpot.new(8).left in game_loop", reads: %i[m], passes: 2) do
      m = 0
      game_loop do
        spot = AnswerSpot.new(8)
        m = spot.left
      end
    end
  end

  # The keeper is made again on every pass, so in Ruby its `@inner ||=` makes a new counter each time.
  def test_an_object_keeping_a_changing_object_made_in_the_game_loop_is_refused
    refused("AnswerKeeper.new.bump in game_loop", /AnswerKeeper.*above the game loop/m) do
      m = 0
      game_loop do
        keeper = AnswerKeeper.new
        m = keeper.bump
      end
    end
  end

  def test_an_object_handing_out_a_kept_changing_object_made_in_the_game_loop_is_refused
    refused("AnswerLazyKeeper.new(1).counter in game_loop", /AnswerLazyKeeper.*above the game loop/m) do
      m = 0
      game_loop do
        keeper = AnswerLazyKeeper.new(1)
        m = keeper.counter.bump
      end
    end
  end

  # Kept itself, the keeper keeps its counter too, in Ruby as in the game.
  def test_an_object_keeping_a_changing_object_kept_with_or_equals
    agrees("@keeper ||= AnswerKeeper.new", reads: %i[m n], passes: 3) do
      m = n = 0
      game_loop do
        @keeper ||= AnswerKeeper.new
        @lazy ||= AnswerLazyKeeper.new(1)
        m = @keeper.bump
        n = @lazy.counter.bump
      end
    end
  end

  def test_an_object_keeping_a_changing_object_made_above_the_game_loop
    agrees("AnswerKeeper.new above game_loop", reads: %i[m n], passes: 3) do
      keeper = AnswerKeeper.new
      lazy = AnswerLazyKeeper.new(1)
      m = n = 0
      game_loop do
        m = keeper.bump
        n = lazy.counter.bump
      end
    end
  end

  # Which `||=` runs first decides what `@counter` holds in Ruby; the game cannot follow that.
  def test_one_instance_variable_kept_as_different_objects_in_two_routines_is_refused
    refused("@counter ||= two classes in two funcs", /@counter.*AnswerTallCounter/m) do
      m = k = passes = 0
      func(:answer_keeps_counter) { m = (@counter ||= AnswerCounter.new).bump }
      func(:answer_keeps_tall_counter) { k = (@counter ||= AnswerTallCounter.new).bump }
      game_loop do
        passes += 1
        call :answer_keeps_tall_counter
        call :answer_keeps_counter if passes > 1
      end
    end
  end

  def test_one_instance_variable_kept_as_the_same_object_in_two_routines
    agrees("@counter ||= one class in two funcs", reads: %i[m k], passes: 3) do
      m = k = passes = 0
      func(:answer_keeps_counter_first) { m = (@counter ||= AnswerCounter.new).bump }
      func(:answer_keeps_counter_second) { k = (@counter ||= AnswerCounter.new).bump }
      game_loop do
        passes += 1
        call :answer_keeps_counter_second
        call :answer_keeps_counter_first if passes > 1
      end
    end
  end

  # A local from above the loop keeps what `||=` gave it, in Ruby too.
  def test_a_changing_object_kept_in_a_local_from_above_the_game_loop
    agrees("c = nil above, c ||= AnswerCounter.new in game_loop", reads: %i[m], passes: 3) do
      m = 0
      c = nil
      game_loop do
        c ||= AnswerCounter.new
        m = c.bump
      end
    end
  end

  # Set back to nil in the loop, Ruby makes a new counter on the next pass.
  def test_a_changing_object_kept_in_a_local_the_game_loop_sets_again_is_refused
    refused("c ||= AnswerCounter.new; c = nil in game_loop", /above the game loop/) do
      m = 0
      c = nil
      game_loop do
        c ||= AnswerCounter.new
        m = c.bump
        c = nil if m == 2
      end
    end
  end

  # A local the loop sets itself is new on every pass.
  def test_a_changing_object_kept_in_a_local_of_the_game_loop_is_refused
    refused("c = nil; c ||= AnswerCounter.new in game_loop", /above the game loop/) do
      m = 0
      game_loop do
        c = nil
        c ||= AnswerCounter.new
        m = c.bump
      end
    end
  end

  def test_a_fraction_asked_a_verb_a_game_number_does_not_answer_is_refused
    refused("@x.floor after @x += 0.5", /does not answer `floor`/) do
      fraction = AnswerFraction.new
      w = 0
      game_loop do
        fraction.step
        w = fraction.whole
      end
    end
  end

  def test_an_object_of_a_class_with_no_name
    agrees("Class.new(AnswerTicker)", reads: %i[a], passes: 3) do
      ticker = Class.new(AnswerTicker).new
      a = 0
      game_loop do
        a = ticker.shown
        ticker.tick
      end
    end
  end

  def test_setting_up_runs_once
    agrees("a part counting itself made", reads: %i[i h], passes: 3) do
      named = AnswerNamed.new(AnswerMadeCount.new)
      i = h = 0
      game_loop do
        named.hit
        i = named.id
        h = named.hits
      end
    end
  end

  # A part made outside the game's block, as one kept in a constant of a game file is, and the game
  # built twice, as a build for two consoles does: each build plays it from where Ruby left it.
  def test_a_part_made_outside_the_game_built_twice
    ticker = AnswerTicker.new
    game = proc do
      a = 0
      game_loop do
        a = ticker.shown
        ticker.tick
      end
    end

    first = game_player.run(built_program(&game), frames: 3)[:a]
    second = game_player.run(built_program(&game), frames: 3)[:a]

    assert_equal [20, 20], [first, second]
  end

  # A build stopped by an error part way through game code leaves no builder recording: plain Ruby
  # run after it answers as Ruby does.
  def test_plain_ruby_after_a_build_that_failed
    assert_raises(ArgumentError) do
      built_program do
        k = 0
        game_loop do
          k += 1
          raise ArgumentError, "stopped inside a game test" if k == 3
        end
      end
    end
    ticker = AnswerTicker.new
    3.times { ticker.tick }

    assert_equal 30, ticker.shown
  end

  # Two lamps, the second switched first: each keeps the name of the order it was made in, as it
  # would with `game_variables`, so a save made before still finds each number.
  def test_objects_of_one_class_are_named_in_the_order_they_were_made
    player = game_player.run(built_program do
      first = AnswerLamp.new
      second = AnswerLamp.new
      game_loop do
        second.switch
        first.lit
      end
    end, frames: 1)

    assert_equal [0, 1], [player[:answer_lamp_lit], player[:answer_lamp_lit_2]]
  end

  # The same for two Structs: the second changed first still reads as the second.
  def test_structs_of_one_class_are_named_in_the_order_they_were_made
    player = game_player.run(built_program do
      first = AnswerPoint.new(1, 0, 0)
      second = AnswerPoint.new(5, 0, 0)
      game_loop do
        second.x += 1
        first.x += 2
      end
    end, frames: 1)

    assert_equal [3, 6], [player[:answer_point_x], player[:answer_point_x_2]]
  end

  def test_swap
    agrees("a, b = b, a", reads: %i[a b], passes: 3) do
      a = 3
      b = 7
      game_loop { a, b = b, a }
    end
  end

  def test_succ_and_pred
    known_gap("succ and pred", gap: "floor, round, succ, ** and divmod on a game number stop with Ruby's raw error",
                               reads: %i[m n]) do
      a = 3
      m = n = 0
      game_loop do
        a += 1 if pressed(:a)
        m = a.succ
        n = a.pred
      end
    end
  end

  def test_fraction_to_whole
    agrees("to_i on a fraction", reads: %i[m]) do
      f = 1.5
      m = 0
      game_loop do
        f += 0.25
        m = f.to_i
      end
    end
  end

  def test_floor_division_of_a_negative_number
    known_gap("-7 / 2", gap: "Dividing a negative game number rounds toward zero, where Ruby rounds down",
                        reads: %i[m n]) do
      a = -7
      m = n = 0
      game_loop do
        a += 0 if pressed(:a)
        m = a / 2
        n = a % 2
      end
    end
  end

  def test_rounding_a_fraction
    known_gap("floor and round", gap: "floor, round, succ, ** and divmod on a game number stop with Ruby's raw error",
                                 reads: %i[m n]) do
      f = 1.5
      m = n = 0
      game_loop do
        f += 0.25
        m = f.floor
        n = f.round
      end
    end
  end

  def test_power_and_divmod
    known_gap("** and divmod", gap: "floor, round, succ, ** and divmod on a game number stop with Ruby's raw error",
                               reads: %i[m q r]) do
      a = 3
      m = q = r = 0
      game_loop do
        a += 1 if pressed(:a)
        m = a**2
        q, r = a.divmod(2)
      end
    end
  end

  # --- loops with break and next ---

  def test_while_with_a_test_that_changes_a_number
    agrees("while (calls += 1) < lim with break", reads: %i[calls i]) do
      calls = 0
      i = 0
      lim = 100
      game_loop do
        calls = 0
        i = 0
        while (calls += 1) < lim
          i += 1
          break if i == 3
        end
        lim += 0 if pressed(:a)
      end
    end
  end

  def test_break_on_one_side_of_an_if
    agrees("break in if, else counts", reads: %i[y z i]) do
      n = 10
      i = y = z = 0
      game_loop do
        i = y = z = 0
        while i < n
          i += 1
          if i == 3
            break
          else
            y += 1
          end
          z += 1
        end
      end
    end
  end

  def test_next_in_an_elsif_chain
    agrees("next in elsif", reads: %i[a b c]) do
      n = 6
      i = a = b = c = 0
      game_loop do
        i = a = b = c = 0
        while i < n
          i += 1
          if i == 2
            a += 1
          elsif i % 3 == 0
            next
          else
            b += 1
          end
          c += 1
        end
      end
    end
  end

  def test_break_in_a_case
    agrees("break in case", reads: %i[i s]) do
      n = 10
      i = s = 0
      game_loop do
        i = s = 0
        while i < n
          i += 1
          case i
          when 4 then break
          end
          s += 1
        end
      end
    end
  end

  def test_next_and_break_in_nested_loops
    agrees("outer next, inner break", reads: %i[outer inner tail]) do
      n = 4
      o = outer = inner = tail = 0
      game_loop do
        o = outer = inner = tail = 0
        while o < n
          o += 1
          next if o == 2

          outer += 1
          k = 0
          while k < n
            k += 1
            break if k == 2

            inner += 1
          end
          next if o == 3

          tail += 1
        end
      end
    end
  end

  def test_loop_do_with_break
    agrees("loop do with break", reads: %i[x pre]) do
      g = 5
      x = pre = 0
      game_loop do
        x = pre = 0
        loop do
          pre += 1
          x += 1
          break if x > g
        end
      end
    end
  end

  def test_next_in_a_ruby_loop_inside_a_game_loop
    agrees("each over a Ruby Array with next, in a while with break", reads: %i[t i]) do
      n = 5
      i = t = 0
      game_loop do
        i = t = 0
        while i < n
          i += 1
          [1, 2, 3].each do |k|
            next if k == 2

            t += k
          end
          break if i == 2
        end
      end
    end
  end

  def test_times_over_a_game_number_with_next_and_break
    agrees("n.times with next and break", reads: %i[total last]) do
      n = 10
      total = last = 0
      game_loop do
        total = last = 0
        n.times do |k|
          next if k.even?

          last = k
          break if k >= 5

          total += k
        end
      end
    end
  end

  def test_until_with_next_and_break
    agrees("until with next and break", reads: %i[i s]) do
      n = 10
      i = s = 0
      game_loop do
        i = s = 0
        until i >= n
          i += 1
          next if i == 1
          break if i == 4

          s += i
        end
      end
    end
  end

  def test_loop_do_switching_late
    agrees("loop do whose test turns game late", reads: %i[last hits]) do
      g = 10
      last = hits = 0
      game_loop do
        last = 0
        k = 0
        loop do
          k += 1
          if k > 2
            last = k
            break if k > g
          end
        end
        hits += 1
      end
    end
  end

  def test_times_with_a_while_inside
    agrees("times with next, while with break", reads: %i[s]) do
      n = 4
      s = 0
      game_loop do
        s = 0
        n.times do |a|
          next if a == 1

          b = 0
          while b < n
            b += 1
            break if b > a

            s += 10
          end
          s += 1
        end
      end
    end
  end

  def test_loop_do_inside_a_while
    agrees("loop do inside a while, entered again", reads: %i[tot]) do
      n = 3
      o = tot = 0
      game_loop do
        o = tot = 0
        while o < n
          o += 1
          c = 0
          loop do
            c += 1
            tot += 1
            break if c > o
          end
        end
      end
    end
  end

  def test_begin_end_while_with_break_is_refused
    refused("begin ... end while, with break", /loop do/) do
      n = 10
      i = 0
      game_loop do
        i = 0
        begin
          i += 1
          break if i == 3
        end while i < n
      end
    end
  end

  def test_loop_do_reading_a_ruby_value_that_changes_is_refused
    refused("loop do over steps.next", /steps\.next/) do
      g = 10
      total = rounds = 0
      game_loop do
        total = rounds = 0
        steps = (1..100).to_a.each
        loop do
          total += steps.next
          rounds += 1
          break if total > g
        end
      end
    end
  end

  # --- Arrays of numbers ---

  def test_an_item_does_not_change_the_number_it_came_from
    agrees("pair = [a, b]; pair[0] += 1", reads: %i[a pair]) do
      a = 1
      b = 1
      pair = [a, b]
      game_loop do
        pair[0] += 1
        a += 0 if a > 100
        b += 0 if b > 100
      end
    end
  end

  def test_a_local_holding_an_item
    agrees("item = marks[0], changed under a test", reads: %i[shown]) do
      marks = Array.new(4, 0)
      passes = shown = 0
      game_loop do
        marks[0] = 5
        item = marks[0]
        item += 10 if passes == 99
        shown = item
        passes += 1
      end
    end
  end

  def test_a_setting_up_local_holding_an_item
    agrees("first = marks[0] while setting up", reads: %i[shown]) do
      marks = Array.new(4, 0)
      first = marks[0]
      passes = shown = 0
      game_loop do
        marks[0] = 5
        first += 10 if passes == 5
        shown = first
        passes += 1
      end
    end
  end

  def test_an_item_changed_under_a_test
    agrees("marks[1] += 10 under a test", reads: %i[shown marks], passes: 3) do
      marks = Array.new(4, 0)
      passes = shown = 0
      game_loop do
        marks[1] += 10 if passes == 1
        shown = marks[1]
        passes += 1
      end
    end
  end

  def test_sorting_numbers_biggest_first
    agrees("sort_by! { -n } with negatives", reads: %i[marks]) do
      marks = Array.new(4, 0)
      game_loop do
        marks[0] = -5
        marks[1] = 7
        marks[2] = -100
        marks[3] = 0
        marks.sort_by! { |n| -n }
      end
    end
  end

  def test_pushing_and_shifting_numbers
    agrees("<<, shift and the item shift hands back", reads: %i[trail took total], passes: 6) do
      trail = Array.new(capacity: 4)
      x = took = total = 0
      game_loop do
        x += 1
        took = trail.shift if trail.size == 4
        trail << x
        total = trail.sum
      end
    end
  end

  def test_a_full_array_of_numbers_stops
    stops("a push onto a full Array of numbers", /`trail` is full/, passes: 6) do
      trail = Array.new(capacity: 4)
      x = 0
      game_loop do
        x += 1
        trail << x
      end
    end
  end

  def test_equality_questions_on_game_numbers
    known_gap("uniq and index", gap: "uniq, index, tally and other equality questions on game numbers build without a word and answer wrong",
                                reads: %i[m n]) do
      a = 3
      b = 3
      m = n = 0
      game_loop do
        a += 1 if pressed(:a)
        m = [a, b].uniq.size
        n = [b, a].index(a)
      end
    end
  end

  # --- Arrays of Structs ---

  def test_a_thing_kept_past_its_walk
    agrees("last = s after a walk", reads: %i[out]) do
      pts = Array.new(capacity: 4)
      out = 0
      game_loop do
        pts.clear
        pts << AnswerPoint.new(10, 0, 0)
        pts << AnswerPoint.new(20, 0, 0)
        last = nil
        pts.each { |s| last = s }
        out = last.x
      end
    end
  end

  def test_a_thing_kept_under_a_test
    agrees("pick = s if s.x == 10", reads: %i[out], passes: 1) do
      pts = Array.new(capacity: 4)
      out = 0
      game_loop do
        pts << AnswerPoint.new(10, 0, 0)
        pts << AnswerPoint.new(20, 0, 0)
        pick = nil
        pts.each { |s| pick = s if s.x == 10 }
        out = pick.x
      end
    end
  end

  def test_things_compared
    agrees("==, eql? and equal? between things", reads: %i[same alike one], passes: 1) do
      pts = Array.new(capacity: 4)
      same = alike = one = 0
      game_loop do
        pts << AnswerPoint.new(10, 0, 0)
        pts << AnswerPoint.new(10, 0, 0)
        pts.each { |a| pts.each { |b| same += 1 if a == b } }
        pts.each { |a| alike += 1 if a.eql?(a) }
        pts.each { |a| pts.each { |b| one += 1 if a.equal?(b) } }
      end
    end
  end

  def test_a_thing_from_a_local_or_with_tap
    agrees("a thing put in from a local, or changed with tap", reads: %i[pts], passes: 1) do
      pts = Array.new(capacity: 4)
      game_loop do
        s = AnswerPoint.new(10, 0, 0)
        pts << s
        pts << AnswerPoint.new(1, 0, 0).tap { |p| p.x = 9 }
      end
    end
  end

  def test_things_moved_between_arrays
    agrees("a.each { |s| b << s }", reads: %i[out out2]) do
      a = Array.new(capacity: 4)
      b = Array.new(capacity: 4)
      out = out2 = 0
      game_loop do
        a.clear
        b.clear
        a << AnswerPoint.new(10, 0, 0)
        a.each { |s| b << s }
        out = b.size
        b.each { |s| out2 = s.x }
      end
    end
  end

  # Ruby makes y a Float the first time it adds one; the game keeps a field one kind, so it says
  # where to write `.to_f`.
  def test_a_fraction_added_to_a_whole_field_is_refused
    refused("s.y += s.vy, vy given 0.5 in a walk", /\.to_f/) do
      pts = Array.new(capacity: 4)
      started = 0
      game_loop do
        if started == 0
          pts << AnswerPoint.new(10, 0, 0)
          started = 1
        end
        pts.each do |s|
          s.vy = 0.5
          s.y += s.vy
        end
      end
    end
  end

  def test_an_array_filled_while_building
    agrees("filled while building, read in the game", reads: %i[out]) do
      walls = Array.new(capacity: 4)
      walls << AnswerPoint.new(1, 2, 3)
      walls << AnswerPoint.new(4, 5, 6)
      out = 0
      game_loop { walls.each { |w| out += w.x } }
    end
  end

  def test_two_shifts_in_a_walk
    agrees("two shifts in one turn of a walk", reads: %i[out]) do
      pts = Array.new(capacity: 4)
      out = 0
      game_loop do
        pts.clear
        pts << AnswerPoint.new(1, 0, 0)
        pts << AnswerPoint.new(2, 0, 0)
        pts << AnswerPoint.new(3, 0, 0)
        pts.each do |s|
          pts.shift if s.x == 1
          pts.shift if s.x == 1
        end
        out = pts.size
      end
    end
  end

  def test_first_of_an_array_is_refused
    refused("pts.first.x", /first/) do
      pts = Array.new(capacity: 4)
      out = 0
      game_loop do
        pts.clear
        pts << AnswerPoint.new(7, 0, 0)
        out = pts.first.x
      end
    end
  end

  def test_delete_if_in_a_walk
    agrees("delete_if inside each", reads: %i[out], passes: 1) do
      pts = Array.new(capacity: 4)
      out = 0
      game_loop do
        pts << AnswerPoint.new(1, 0, 0)
        pts << AnswerPoint.new(2, 0, 0)
        pts.each { pts.delete_if { |t| t.x == 2 } }
        out = pts.size
      end
    end
  end

  def test_a_structs_method_calling_another
    agrees("step asks speed", reads: %i[out], passes: 3) do
      ms = Array.new(capacity: 2)
      out = started = 0
      game_loop do
        if started == 0
          ms << AnswerMover.new(4, 0)
          started = 1
        end
        ms.each(&:step)
        ms.each { |m| out = m.x }
      end
    end
  end

  def test_a_field_called_index
    agrees("a member named index", reads: %i[out out2], passes: 1) do
      cards = Array.new(capacity: 4)
      out = out2 = 0
      game_loop do
        cards << AnswerCard.new(1, 2, 7)
        cards.each { |c| out = c.index }
        cards.each { |c| c.index += 1 }
        cards.each { |c| out2 = c.index }
      end
    end
  end

  def test_members_named_as_a_things_own_words
    agrees("members named left, move, capacity and rate", reads: %i[boxes total], passes: 2) do
      boxes = Array.new(capacity: 4)
      total = started = 0
      game_loop do
        if started == 0
          boxes << AnswerBox.new(1, 2, 3, 4)
          started = 1
        end
        boxes.each do |b|
          b.left += b.rate
          b.move += 1
          total = b.left + b.move + b.capacity
        end
      end
    end
  end

  def test_two_sorts_on_one_line
    agrees("two sort_by! on one line", reads: %i[first]) do
      sparks = Array.new(capacity: 4)
      first = started = 0
      game_loop do
        if started == 0
          [[3, 10], [1, 30], [2, 20]].each { |x, y| sparks << AnswerPoint.new(x, y, 0) }
          started = 1
        end
        sparks.sort_by! { |s| -s.y }; sparks.sort_by! { |s| -s.x }
        first = 0
        sparks.each { |s| first = s.x if first == 0 }
      end
    end
  end

  def test_sort_by_several_fields
    agrees("sort_by! { [s.y, -s.x] }", reads: %i[o1 o2 o3 o4]) do
      sparks = Array.new(capacity: 6)
      started = o1 = o2 = o3 = o4 = 0
      game_loop do
        if started == 0
          [[1, 20], [2, 10], [3, 20], [4, 10]].each { |x, y| sparks << AnswerPoint.new(x, y, 0) }
          started = 1
        end
        sparks.sort_by! { |s| [s.y, -s.x] }
        sparks.each_with_index do |s, at|
          o1 = s.x if at == 0
          o2 = s.x if at == 1
          o3 = s.x if at == 2
          o4 = s.x if at == 3
        end
      end
    end
  end

  def test_a_sort_in_a_routine_called_in_a_walk_is_refused
    refused("sort in a func called inside a walk", /walk/) do
      sparks = Array.new(capacity: 4)
      visits = started = 0
      func :order do
        sparks.sort_by!(&:y)
      end
      game_loop do
        if started == 0
          [[1, 30], [2, 20], [3, 10]].each { |x, y| sparks << AnswerPoint.new(x, y, 0) }
          started = 1
        end
        visits = 0
        sparks.each do |s|
          visits = (visits * 10) + s.x
          call :order if s.x == 1
        end
      end
    end
  end

  def test_sort_with_a_comparing_block
    agrees("sort! { |p, q| q.y <=> p.y }", reads: %i[a]) do
      s = Array.new(capacity: 3)
      started = a = 0
      game_loop do
        if started == 0
          [[30, 2], [10, 1], [50, 2]].each { |x, y| s << AnswerLow.new(x, y) }
          started = 1
        end
        s.sort! { |p, q| q.y <=> p.y }
        s.each_with_index { |t, at| a = t.x if at == 0 }
      end
    end
  end

  def test_max_of_things_takes_the_first_of_ties
    agrees("max of Comparable things, and max with a block", reads: %i[a b]) do
      s = Array.new(capacity: 3)
      started = a = b = 0
      game_loop do
        if started == 0
          [[30, 2], [10, 1], [50, 2]].each { |x, y| s << AnswerLow.new(x, y) }
          started = 1
        end
        a = s.max.x
        b = s.max { |p, q| p.x <=> q.x }.x
      end
    end
  end

  def test_eql_compares_every_field
    agrees("eql? against the min", reads: %i[a]) do
      s = Array.new(capacity: 3)
      started = a = 0
      game_loop do
        if started == 0
          s << AnswerLow.new(1, 2)
          s << AnswerLow.new(3, 2)
          started = 1
        end
        a = 0
        first = s.min
        s.each { |t| a += 1 if t.eql?(first) }
      end
    end
  end

  # The order a game can sort by is fields compared one by one, so the refusal shows the
  # same order written that way, `other.y <=> y`.
  def test_a_turned_round_order_is_refused
    refused("sort! by -(y <=> other.y)", /other\.y <=> y/) do
      s = Array.new(capacity: 3)
      started = a = 0
      game_loop do
        if started == 0
          [[30, 2], [10, 1], [50, 2]].each { |x, y| s << AnswerHigh.new(x, y) }
          started = 1
        end
        s.sort!
        s.each_with_index { |t, at| a = t.x if at == 0 }
      end
    end
  end

  def test_min_of_two_is_refused
    refused("min(2)", /min/) do
      s = Array.new(capacity: 3)
      started = b = 0
      game_loop do
        if started == 0
          s << AnswerLow.new(1, 2)
          started = 1
        end
        b = s.min(2).size
      end
    end
  end

  def test_an_order_that_changes_a_field_is_refused
    refused("<=> with a side effect", /<=>/) do
      s = Array.new(capacity: 3)
      started = 0
      game_loop do
        if started == 0
          s << AnswerCounted.new(1, 2, 0)
          started = 1
        end
        s.sort!
      end
    end
  end

  def test_clamp_between_two_things_is_refused
    refused("clamp between two different things", /clamp/) do
      s = Array.new(capacity: 3)
      started = a = 0
      game_loop do
        if started == 0
          s << AnswerLow.new(1, 2)
          started = 1
        end
        a = s.min.clamp(s.max, s.min).x
      end
    end
  end

  def test_a_full_array_of_structs_stops
    stops("a push onto a full Array of Structs", /`pts` is full/, passes: 1) do
      pts = Array.new(capacity: 2)
      game_loop do
        pts << AnswerPoint.new(1, 0, 0)
        pts << AnswerPoint.new(2, 0, 0)
        pts << AnswerPoint.new(3, 0, 0)
      end
    end
  end

  def test_a_push_in_a_walk_with_room
    agrees("a push in a walk is one of the things at once", reads: %i[nines newest pts], passes: 1) do
      pts = Array.new(capacity: 4)
      nines = newest = 0
      2.times { |n| pts << AnswerPoint.new(n, 0, 0) }
      game_loop do
        pts.each do |s|
          if s.x == 0
            pts << AnswerPoint.new(9, 0, 0)
            nines = pts.count { |t| t.x == 9 }
            pts.reverse_each { |t| newest = t.x if newest == 0 }
          end
        end
      end
    end
  end

  def test_a_shift_then_a_push_in_a_walk_of_a_full_array
    known_gap("shift then << in a walk of a full Array", gap: "a push in a walk of a full Array finds the room Ruby has",
                                                       reads: %i[pts], passes: 1) do
      pts = Array.new(capacity: 4)
      4.times { |n| pts << AnswerPoint.new(n, 0, 0) }
      game_loop do
        pts.each do |s|
          if s.x == 0
            pts.shift
            pts << AnswerPoint.new(9, 0, 0)
          end
        end
      end
    end
  end

  def test_an_object_pushing_into_arrays_it_is_handed
    agrees("initialize pushes into handed Arrays", reads: %i[notes pts], passes: 4) do
      notes = Array.new(capacity: 8)
      pts = Array.new(capacity: 8)
      game_loop do
        AnswerHanded.new(notes, pts, 7)
        # Never true: these lines tell the build both are Arrays the game changes.
        if notes.size > 8
          notes << 1
          pts << AnswerPoint.new(1, 0, 0)
        end
      end
    end
  end
end
