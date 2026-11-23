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
