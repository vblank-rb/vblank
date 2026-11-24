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

  # --- blocks ---

  # A block that reads its argument as `it` or `_1` is game code like any other.
  def test_a_block_reading_it_changes_a_game_number
    agrees("[2].each { score += it }", reads: %i[score], passes: 3) do
      score = 0
      game_loop { [2].each { score += it } }
    end
  end

  def test_a_block_reading_numbered_parameters_changes_a_game_number
    agrees("[[2, 3]].each { score += _1 * _2 }", reads: %i[score], passes: 3) do
      score = 0
      game_loop { [[2, 3]].each { score += _1 * _2 } }
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

  # Ruby asks these by eql? and hash, or by ==, item by item, while building. A number the game
  # works out has neither answer then, so each is refused where an item, an argument or a block's
  # answer is one.
  EQUALITY_QUESTIONS = [
    "[a, b].uniq", "[1, 2].uniq { n + a }", "[a, b].tally", "[a, b].group_by", "[1, 2].group_by { n + a }",
    "[a, b].index(7)", "[a, b].find_index(7)", "[a, b].rindex(7)", "[1, 7].index(a)", "[a, b] - [7]",
    "[a, b] & [7]", "[a, b] | [7]", "[1, 7] - [a]", "[a, b].difference([7])", "[a, b].intersection([7])",
    "[a, b].union([7])", "[a, b].intersect?([7])", "[a, b].delete(7)", "sizes.counts.uniq",
    "[p, q].index(q)", "[p, q].uniq", "[p, q] - [q]"
  ].freeze

  def test_equality_questions_on_game_numbers_are_refused
    EQUALITY_QUESTIONS.each { |name| refused(name, /compares the items/, &equality_question(name)) }
  end

  # The same questions on Ruby's own numbers are Ruby's, answered while building, and `-` between
  # numbers is still a sum.
  def test_equality_questions_on_plain_numbers_agree
    agrees("[1, 2, 2].uniq and the others", reads: %i[m n o p q r s]) do
      a = 9
      m = n = o = p = q = r = s = 0
      game_loop do
        a += 1
        m = [1, 2, 2].uniq.size
        n = [1, 2, 2].tally[2]
        o = [1, 2, 7].index(7)
        p = ([1, 2, 7] - [7]).size
        q = ([1, 2] | [7]).size
        r = a - 3
        s = 3 - a
      end
    end
  end

  def test_range_and_list_tests
    agrees("include? and case on a range", reads: %i[m n o]) do
      a = 3
      m = n = o = p = 0
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
      m = n = o = p = 0
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
      m = n = o = p = 0
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

  # Named, its Array is a variable per slot from its first number, before another part's line
  # indexes it at a worked-out place through its reader: refused, naming a method of its class.
  def test_a_named_array_changed_through_its_reader_by_another_part_is_refused
    refused("@tallies.counts[at] += 1, counts named", /in its class/) do
      keeper = AnswerTallyKeeper.new(AnswerNamedTallies.new)
      at = 2
      n = 0
      game_loop do
        at = (at + 1) % 3
        keeper.bump(at)
        n = keeper.first
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

  # A reader of the same name in another class, indexed at a worked-out place (AnswerTallies, and
  # AnswerTallyKeeper's file line), leaves a named Array read only at known indexes a variable per
  # slot, as its save keeps it.
  def test_a_named_array_beside_another_class_reader_of_its_name_keeps_a_variable_per_slot
    sizes_game = proc do
      sizes = AnswerNamedSizes.new
      tallies = AnswerTallies.new
      at = 0
      n = m = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
        n = sizes.counts[0] + sizes.counts[1]
        m = tallies.counts[at]
      end
    end
    agrees("sizes.counts[0] beside tallies.counts[at]", reads: %i[n m], passes: 4, &sizes_game)
    assert_equal [:answer_tallies_counts], list_names(built_program(&sizes_game))
  end

  # A part made on every pass is a new one in Ruby, its Array starting again each time; the game
  # would keep one list from power-on.
  def test_a_part_made_every_pass_indexed_through_its_reader_is_refused
    refused("t = Tallies.new; t.counts[at] += 1, in the game loop", /every frame/) do
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        tallies = AnswerTallies.new
        tallies.counts[at] += 1
        n = tallies.counts[1] + tallies.counts[2]
      end
    end
  end

  def test_a_part_made_under_a_game_test_indexed_through_its_reader_is_refused
    refused("t = Tallies.new if at == 1; t.counts[at] += 1", /every frame/) do
      tallies = nil
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        tallies = AnswerTallies.new if at == 1
        tallies.counts[at] += 1 if tallies
        n = tallies ? tallies.counts[1] : 0
      end
    end
  end

  # A named Array of game numbers compared with an Array is equal only where the sizes match and
  # every pair of items is equal, as Ruby's Array#== is.
  def test_named_array_compared_with_an_array
    agrees("sizes.counts == [...]", reads: %i[m n o p q r s t u v w], passes: 3) do
      sizes = AnswerNamedSizes.new
      m = n = o = p = q = r = s = t = u = v = w = 0
      game_loop do
        sizes.counts[0] += 1
        m = sizes.counts == [6, 4] ? 1 : 2
        n = sizes.counts == [5, 4] ? 1 : 2
        o = sizes.counts == [6, 4, 5] ? 1 : 2
        p = sizes.counts != [6, 4] ? 1 : 2
        q = sizes.counts != [5, 4] ? 1 : 2
        r = [6, 4] == sizes.counts ? 1 : 2
        s = [5, 4] == sizes.counts ? 1 : 2
        t = sizes.counts == [m + 5, 4] ? 1 : 2
        u = sizes.counts.eql?([6, 4]) ? 1 : 2
        v = sizes.counts.eql?([6.0, 4]) ? 1 : 2
        w = [sizes.counts[0], 4] == [5, 4] ? 1 : 2
      end
    end
  end

  # The same for a part's Array the game keeps as a list, changed at an index it works out.
  def test_kept_array_compared_with_an_array
    agrees("tallies.counts == [...]", reads: %i[m n o p q r s], passes: 3) do
      tallies = AnswerTallies.new
      at = 0
      m = n = o = p = q = r = s = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
        m = tallies.counts == [1, 1, 1] ? 1 : 2
        n = tallies.counts == [1, 1, 0] ? 1 : 2
        o = tallies.counts == [1, 1] ? 1 : 2
        p = tallies.counts != [1, 1, 1] ? 1 : 2
        q = [1, 1, 1] == tallies.counts ? 1 : 2
        r = tallies.counts.eql?([1, 1, 1]) ? 1 : 2
        s = tallies.counts.eql?([1.0, 1, 1]) ? 1 : 2
      end
    end
  end

  # Two Arrays the game keeps would both need their sizes and items as the game plays.
  def test_two_kept_arrays_compared_are_refused
    refused("a.counts == b.counts", /compare the items one at a time/) do
      a = AnswerTallies.new
      b = AnswerTallies.new
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        a.counts[at] += 1
        b.counts[at] += 1
        n = a.counts == b.counts ? 1 : 2
      end
    end
  end

  # Part of a named Array would hold its game variables, where Ruby's part is a copy.
  def test_part_of_a_named_array_is_refused
    refused("c = sizes.counts[0..]; c[0] += 5", /a part of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        part = sizes.counts[0..]
        part[0] += 5
        n = sizes.counts[0]
      end
    end
  end

  # A copy of a named Array would hold its game variables too, where Ruby's copy is its own.
  def test_copy_of_a_named_array_is_refused
    refused("c = sizes.counts.dup; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.dup
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = sizes.counts.clone; c[1] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.clone
        copy[1] += 5
        n = sizes.counts[1]
      end
    end
    refused("c = sizes.counts.reverse; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.reverse
        copy[0] += 5
        n = sizes.counts[1]
      end
    end
    refused("c = sizes.counts.rotate; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.rotate
        copy[0] += 5
        n = sizes.counts[1]
      end
    end
    refused("c = sizes.counts.values_at(1, 0); c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.values_at(1, 0)
        copy[0] += 5
        n = sizes.counts[1]
      end
    end
    refused("c = sizes.counts + [0]; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts + [0]
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = sizes.counts.first(2); c[0] += 5", /a part of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        part = sizes.counts.first(2)
        part[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = sizes.counts.take(1); c[0] += 5", /a part of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        part = sizes.counts.take(1)
        part[0] += 5
        n = sizes.counts[0]
      end
    end
  end

  # A new Array of the named Array's own items, made by splat, Array.new or a block that hands
  # each item back, would hold its game variables too.
  def test_new_array_of_a_named_arrays_items_is_refused
    refused("c = [*sizes.counts]; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = [*sizes.counts]
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = Array.new(sizes.counts); c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = Array.new(sizes.counts)
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = sizes.counts.map(&:itself); c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.map(&:itself)
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
    refused("c = sizes.counts.sort_by { 0 }; c[0] += 5", /a copy of it/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.sort_by { 0 }
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
  end

  # The same methods with no block answer an Enumerator, which cannot see what its block hands
  # back, so the block must be given to the method itself.
  def test_items_answered_with_no_block_are_refused
    refused("c = sizes.counts.map.with_index { |c, _| c }; c[0] += 5", /give the block/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        copy = sizes.counts.map.with_index { |count, _at| count }
        copy[0] += 5
        n = sizes.counts[0]
      end
    end
  end

  # A walk whose method answers the Array itself (`each_slice` with its block) is a read.
  def test_each_slice_with_its_block_over_a_named_array_agrees
    agrees("sizes.counts.each_slice(2) { |a, b| n = a + b }", reads: %i[n], passes: 2) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop { sizes.counts.each_slice(2) { |first, second| n = first + second } }
    end
  end

  # A block that works out new numbers from the items makes numbers of its own, as in Ruby.
  def test_map_to_new_numbers_of_a_named_array_agrees
    agrees("c = sizes.counts.map { |c| c + 1 }; c[0] += 5", reads: %i[n m], passes: 2) do
      sizes = AnswerNamedSizes.new
      n = m = 0
      game_loop do
        copy = sizes.counts.map { |count| count + 1 }
        copy[0] += 5
        n = sizes.counts[0]
        m = copy[0]
      end
    end
  end

  # The first or last item alone is one of the Array's numbers, not a part of it.
  def test_first_and_last_item_of_a_named_array_agree
    agrees("sizes.counts.first + sizes.counts.last", reads: %i[n], passes: 2) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop { n = sizes.counts.first + sizes.counts.last }
    end
  end

  # An Array the game keeps is an Array to Ruby's questions about its kind, whatever it is kept as.
  def test_a_kept_array_is_an_array
    agrees("flock.dots.is_a?(Array), kind_of?, instance_of? and case/when Array", reads: %i[a b c d e], passes: 2) do
      flock = AnswerFlock.new
      flock.add(3)
      a = b = c = d = e = 0
      game_loop do
        flock.dots.each { |dot| dot.x += 1 }
        a = flock.dots.is_a?(Array) ? 1 : 2
        b = flock.dots.kind_of?(Enumerable) ? 1 : 2
        c = flock.dots.instance_of?(Array) ? 1 : 2
        d = case flock.dots
            when Hash then 3
            when Array then 1
            else 2
            end
        e = flock.dots.is_a?(Hash) ? 1 : 2
      end
    end
    agrees("dots.is_a?(Array) and case/when Array on an Array of Structs the game fills", reads: %i[a b], passes: 2) do
      dots = Array.new(capacity: 4)
      a = b = 0
      game_loop do
        dots.shift if dots.size == 4
        dots << AnswerPoint.new(1, 0, 0)
        a = dots.kind_of?(Array) ? 1 : 2
        b = case dots
            when Array then 1
            else 2
            end
      end
    end
    agrees("Array === dots and dots.class on an Array of Structs the game fills", reads: %i[a b c], passes: 2) do
      dots = Array.new(capacity: 4)
      a = b = c = 0
      game_loop do
        dots.shift if dots.size == 4
        dots << AnswerPoint.new(1, 0, 0)
        a = Array === dots ? 1 : 2 # rubocop:disable Style/CaseEquality
        b = dots.class == Array ? 1 : 2
        c = Enumerable === dots ? 1 : 2 # rubocop:disable Style/CaseEquality
      end
    end
    agrees("Array === trail and trail.class on an Array of numbers the game changes", reads: %i[a b c], passes: 2) do
      trail = Array.new(capacity: 4)
      a = b = c = 0
      game_loop do
        trail.shift if trail.size == 4
        trail << 1
        a = Array === trail ? 1 : 2 # rubocop:disable Style/CaseEquality
        b = trail.class == Array ? 1 : 2
        c = Hash === trail ? 1 : 2 # rubocop:disable Style/CaseEquality
      end
    end
    agrees("trail.is_a?(Array) and case/when Array on an Array of numbers the game changes",
           reads: %i[a b], passes: 2) do
      trail = Array.new(capacity: 4)
      a = b = 0
      game_loop do
        trail.shift if trail.size == 4
        trail << 1
        a = trail.is_a?(Array) ? 1 : 2
        b = case trail
            when Array then 1
            else 2
            end
      end
    end
  end

  # A game built after one that reads `counts` at a worked-out place builds as it does alone.
  def test_a_game_built_after_another_builds_as_it_does_alone
    alone = proc do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop { n = sizes.counts[1] }
    end
    first = list_names(built_program(&alone))
    built_program do
      tallies = AnswerTallies.new
      at = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
      end
    end
    assert_equal first, list_names(built_program(&alone))
    assert_empty first
  end

  # A part's Array made with room, which its class body puts nothing into, filled while setting
  # up from game code outside the class, from the class reopened, from a subclass and from a
  # module, then walked and changed by game code.
  def test_a_part_array_of_structs_filled_from_outside_its_class
    agrees("flock.dots << Point.new(...), then walked", reads: %i[n], passes: 3) do
      flock = AnswerFlock.new
      flock.dots << AnswerPoint.new(1, 0, 0)
      flock.dots << AnswerPoint.new(2, 0, 0)
      n = 0
      game_loop do
        flock.dots.each { |dot| dot.x += 1 }
        n = flock.total_x
      end
    end
  end

  # The same Array, which nothing is put into before game code asks its size, then filled a thing a
  # pass by a method of its class reopened: nothing showed what it keeps before the game began, so
  # it is still Ruby's, and the add would happen one time while building.
  def test_a_part_array_of_structs_asked_before_anything_is_put_in
    refused("n = flock.dots.size before flock.add", /still a plain Ruby Array/) do
      flock = AnswerFlock.new
      n = 0
      t = 0
      game_loop do
        n = flock.dots.size
        flock.add(n + 1) if flock.dots.size < 4
        t = flock.total_x
      end
    end
  end

  def test_a_part_array_of_structs_filled_by_its_class_reopened
    agrees("add in the class reopened", reads: %i[n], passes: 3) do
      flock = AnswerFlock.new
      flock.add(3)
      n = 0
      game_loop do
        flock.dots.each { |dot| dot.x += 2 }
        n = flock.total_x
      end
    end
  end

  def test_a_part_array_of_structs_filled_by_a_subclass
    agrees("add_big in a subclass", reads: %i[n], passes: 3) do
      flock = AnswerBigFlock.new
      flock.add_big(1)
      flock.add(2)
      n = 0
      game_loop do
        flock.dots.each { |dot| dot.x += 1 }
        n = flock.total_x
      end
    end
  end

  def test_a_part_array_of_structs_filled_by_a_module
    agrees("add_dot in a module", reads: %i[n], passes: 3) do
      flock = AnswerMixedFlock.new
      flock.add_dot(4)
      n = 0
      game_loop do
        flock.dots.each { |dot| dot.x += 1 }
        n = flock.dots.sum(&:x)
      end
    end
  end

  # Game code outside the class puts things into a part's Array that its class body puts nothing
  # into: it is still Ruby's, so the put would happen once, while building. Refused, naming a
  # method of its class as the fix.
  def test_a_part_array_of_structs_filled_in_game_code_from_outside_its_class
    refused("flock.dots << Point.new(...) in the game loop", /a method of its class/) do
      flock = AnswerFlock.new
      n = 0
      at = 0
      game_loop do
        at += 1
        flock.dots << AnswerPoint.new(at, 0, 0) if at < 3
        n = flock.dots.size
      end
    end
  end

  # The same for a part's Array of numbers added to or turned from outside its class, named or not.
  def test_a_part_array_of_numbers_changed_whole_from_outside_its_class_is_refused
    refused("scores.scores << 7", /a method of its class/) do
      scores = AnswerScores.new
      n = 0
      game_loop do
        scores.scores << 7 if n < 6
        n = scores.scores.size
      end
    end
    refused("scores.scores.rotate!", /a method of its class/) do
      scores = AnswerScores.new
      n = 0
      game_loop do
        scores.scores.rotate!
        n = scores.scores[0]
      end
    end
    refused("sizes.counts.rotate!, counts named", /a method of its class/) do
      sizes = AnswerNamedSizes.new
      n = 0
      game_loop do
        sizes.counts.rotate!
        n = sizes.counts[0]
      end
    end
  end

  # Changing it while the game is set up is Ruby's, one time, as Ruby does it there.
  def test_a_part_array_changed_from_outside_while_setting_up_agrees
    agrees("scores.scores << 7 above the game loop", reads: %i[n]) do
      scores = AnswerScores.new
      scores.scores << 7
      n = 0
      game_loop { n = scores.scores.size }
    end
  end

  # A named Array read through its reader at a worked-out place is a variable per slot from its
  # first number, so the line is refused, naming a method of its class as the fix.
  def test_a_named_array_read_through_its_reader_at_a_worked_out_index_is_refused
    refused("tallies.counts[at] += 1, counts named", /in its class/) do
      tallies = AnswerNamedTallies.new
      at = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
      end
    end
  end

  # The Array was read while setting up, where a local may keep it, before game code first
  # changes it through a reader: its numbers would be Ruby's in that local.
  def test_an_array_read_before_game_code_changes_it_through_a_reader_is_refused
    refused("kept = t.counts; t.counts[at] += 1", /before/) do
      tallies = AnswerTallies.new
      kept = tallies.counts
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        tallies.counts[at] += 1
        n = kept.sum
      end
    end
  end

  # Game code read the Array at a known index before another line changed it through a reader.
  def test_an_array_read_by_game_code_before_a_reader_changes_it_is_refused
    refused("n = t.counts[0]; t.counts[at] += 1", /before/) do
      tallies = AnswerTallies.new
      at = 0
      n = 0
      game_loop do
        n = tallies.counts[0]
        at = (at + 1) % 3
        tallies.counts[at] += 1
      end
    end
  end

  # An Array two parts share, one changing it through its reader, the other reading it after.
  def test_an_array_shared_with_a_part_that_only_reads_it_is_refused
    refused("p1.counts[at] += 1, p2.counts[1], one Array", /same Array/) do
      shared = [0, 0, 0]
      one = AnswerSharedTallies.new(shared)
      other = AnswerSharedTallies.new(shared)
      at = 0
      n = 0
      game_loop do
        at = (at + 1) % 3
        one.counts[at] += 1
        n = other.counts[1]
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
    refused("marks = m.marks; marks[at]", /in its class/) do
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

  def test_the_answer_of_a_changed_hash_slot
    agrees("m = (h[:a] += 3), n = (h[:b] -= 1), o = (h[:c] *= 2)", reads: %i[m n o p], passes: 3) do
      h = { a: 1, b: 2, c: 1, d: 0 }
      m = n = o = p = 0
      game_loop do
        m = (h[:a] += 3)
        n = (h[:b] -= 1)
        o = (h[:c] *= 2)
        h[:d] += 5
        p = h[:d]
      end
    end
  end

  def test_a_hash_changed_at_known_keys_and_given_numbers
    agrees("h[:a] = h[:a] + 2, SIDES.each { |s| h[s] += 1 }, h.values.sum", reads: %i[m n o], passes: 3) do
      h = { a: 1, left: 0, right: 5 }
      m = n = o = 0
      game_loop do
        h[:a] = h[:a] + 2
        %i[left right].each { |side| h[side] += 1 }
        m = h[:a]
        n = h[:right]
        o = h.values.sum
      end
    end
  end

  def test_a_hash_kept_from_pass_to_pass_set_to_a_number_written_out
    agrees("m = h[:a], then h[:a] = 5, on a Hash from above the game loop", reads: %i[m n], passes: 3) do
      h = { a: 1 }
      m = n = 0
      game_loop do
        m = h[:a]
        h[:a] = 5
        n += m
      end
    end
  end

  def test_a_hash_made_on_every_pass_starts_again
    agrees("h = { a: 0 } in the game loop, then h[:a] += 2", reads: %i[m n], passes: 3) do
      m = n = 0
      game_loop do
        h = { a: 0, b: 1 }
        h[:a] += 2
        n += 1
        h[:b] += n
        m = h[:a] + h[:b]
      end
    end
  end

  def test_a_hash_changed_only_while_building_stays_ruby
    agrees("h[:a] += 3 above the game loop", reads: %i[m], passes: 2) do
      h = { a: 1 }
      h[:a] += 3
      m = 0
      game_loop { m = h[:a] }
    end
  end

  def test_a_hash_changed_at_a_new_key_is_refused
    refused("h[:z] = 1 on { a: 1 }", /no key :z/) do
      h = { a: 1 }
      game_loop { h[:z] = 1 }
    end
  end

  def test_a_hash_changed_whole_is_refused
    refused("h.store(:a, 2) in the game loop", /one key at a time/) do
      h = { a: 1, b: 2 }
      game_loop { h.store(:a, h[:a] + 1) }
    end
    refused("h.delete(:a) in the game loop", /one key at a time/) do
      h = { a: 1, b: 2 }
      game_loop { h.delete(:a) }
    end
  end

  def test_an_item_given_a_number_with_and_or_or_in_game_code_is_refused
    refused("counts[0] &&= counts[0] + 2 in the game loop", /`counts\[0\] = value`/) do
      counts = [1, 2]
      game_loop { counts[0] &&= counts[0] + 2 }
    end
    refused("h[:a] &&= 5 in the game loop", /`h\[:a\] = value`/) do
      h = { a: 1, b: 2 }
      game_loop do
        h[:b] += 1
        h[:a] &&= 5
      end
    end
    refused("h[:a] ||= true on false in the game loop", /`h\[:a\] = value`/) do
      h = { a: false, b: 2 }
      game_loop do
        h[:b] += 1
        h[:a] ||= true
      end
    end
  end

  def test_values_of_a_hash_of_game_numbers_kept_are_refused
    refused("v = h.values, then h[:a] += 1", /takes a copy/) do
      h = { a: 1, b: 2 }
      m = 0
      game_loop do
        v = h.values
        h[:a] += 1
        m = v[0]
      end
    end
    refused("pairs = h.to_a", /takes a copy/) do
      h = { a: 1, b: 2 }
      m = 0
      game_loop do
        pairs = h.to_a
        h[:a] += 1
        m = pairs[0][1]
      end
    end
  end

  def test_values_of_a_hash_of_game_numbers_read_at_once
    agrees("h.values.sum, .max, .count, .include? and .each after h[:a] += 1", reads: %i[m n o p q], passes: 3) do
      h = { a: 1, b: 2 }
      m = n = o = p = q = 0
      game_loop do
        h[:a] += 1
        m = h.values.sum
        n = h.values.max
        o = h.values.count { |value| value > 2 }
        p = h.values.include?(3) ? 1 : 0
        q = 0
        h.values.each { |value| q += value }
      end
    end
  end

  def test_a_copy_of_a_hash_of_game_numbers_is_refused
    refused("g = h.dup, then h[:a] += 1", /takes a copy/) do
      h = { a: 1, b: 2 }
      g = h.dup
      m = 0
      game_loop do
        h[:a] += 1
        m = g[:a]
      end
    end
    refused("g = h.select { true } in the game loop", /takes a copy/) do
      h = { a: 1, b: 2 }
      m = 0
      game_loop do
        g = h.select { |_key, _value| true }
        h[:a] += 1
        m = g[:a]
      end
    end
    refused("h.merge(c: 3)", /takes a copy/) do
      h = { a: 1, b: 2 }
      game_loop { h[:a] += h.merge(c: 3)[:b] }
    end
  end

  def test_a_hash_of_game_numbers_read_whole
    agrees("h.sum, h.count, h.each_value and h.map with new numbers", reads: %i[m n o p], passes: 3) do
      h = { a: 1, b: 2 }
      m = n = o = p = 0
      game_loop do
        h[:a] += 1
        m = h.sum { |_key, value| value }
        n = h.count
        o = 0
        h.each_value { |value| o += value }
        p = h.map { |_key, value| value * 2 }.sum
      end
    end
  end

  def test_a_hash_holding_true_or_false_switched_by_the_game
    agrees("h[:open] = !h[:open] in the game loop", reads: %i[m n], passes: 3) do
      h = { open: false, count: 0 }
      m = n = 0
      game_loop do
        h[:count] += 1
        h[:open] = !h[:open]
        m = h[:open] ? 1 : 2
        n += 1 if h[:open]
      end
    end
  end

  # A number is never nil or false, so Ruby's `||=` leaves it as it is, on every pass.
  def test_an_item_holding_a_number_left_alone_by_or_in_game_code
    agrees("h[:a] ||= 5 and counts[0] ||= 9 in the game loop", reads: %i[m], passes: 3) do
      h = { a: 1, b: 2 }
      counts = [3, 4]
      m = 0
      game_loop do
        h[:b] += 1
        counts[1] += 1
        h[:a] ||= 5
        counts[0] ||= 9
        m = h[:a] + h[:b] + counts[0] + counts[1]
      end
    end
  end

  def test_an_item_given_a_number_with_and_or_or_while_building
    agrees("counts[0] &&= 7 and h[:b] ||= 4 above the game loop", reads: %i[m], passes: 2) do
      counts = [1, 2]
      h = { a: nil, b: 2 }
      counts[0] &&= 7
      h[:a] ||= 4
      h[:b] ||= 9
      m = 0
      game_loop { m = counts[0] + h[:a] + h[:b] }
    end
  end

  def test_a_hash_changed_while_building_then_by_the_game
    agrees("h[:a] += 10 above the game loop, h[:a] += 1 in it", reads: %i[m], passes: 3) do
      h = { a: 1, b: 2 }
      h[:a] += 10
      h[:b] = 7
      m = 0
      game_loop do
        h[:a] += 1
        m = h[:a] + h[:b]
      end
    end
  end

  def test_a_hash_slot_beside_a_local_of_its_variable_name
    agrees("h[:a] beside a local h_a", reads: %i[m], passes: 3) do
      h = { a: 1 }
      h_a = 100
      m = 0
      game_loop do
        h[:a] += 1
        h_a += 1
        m = h[:a] + h_a
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

  # A draw and a change to another number between the line that gives the field its number and
  # the read leave that number as it was, so the field needs no copy of its own.
  def test_a_struct_field_read_after_unrelated_lines_keeps_no_copy
    game = proc do
      screen :bitmap
      px = 0
      n = m = 0
      game_loop do
        px += 1
        point = AnswerPoint.new(px + 2, 0, 0)
        draw_rect_at(0, 0, 4, 4, :red)
        m += 1
        n = point.x
      end
    end
    agrees("point = AnswerPoint.new(px + 2, ...); a draw; m += 1; n = point.x", reads: %i[n m], passes: 3, &game)
    assert_empty field_copies(&game), "the field keeps a copy, though nothing between can change px"
  end

  # A change to the number the field was given, between, still needs the copy.
  def test_a_struct_field_read_after_its_number_changes_keeps_a_copy
    game = proc do
      screen :bitmap
      px = 0
      n = 0
      game_loop do
        px += 1
        point = AnswerPoint.new(px + 2, 0, 0)
        draw_rect_at(0, 0, 4, 4, :red)
        px += 5
        n = point.x
      end
    end
    agrees("point = AnswerPoint.new(px + 2, ...); px += 5; n = point.x", reads: %i[n px], passes: 3, &game)
    refute_empty field_copies(&game)
  end

  # A timer's handler runs between any two lines of the game on a console, so a number it changes
  # can change between the line that gives the field its number and the read: the copy stays. Plain
  # Ruby has no timer, so the answer is held to Ruby's rule instead: the field holds the number
  # px had on its line.
  def test_a_struct_field_read_after_a_draw_keeps_a_copy_of_a_number_a_timer_changes
    game = proc do
      screen :bitmap
      px = 0
      n = m = 0
      timer(:beat, per_second: 60).on_tick { px += 10 }
      game_loop do
        px += 1
        point = AnswerPoint.new(px + 2, 0, 0)
        draw_rect_at(0, 0, 4, 4, :red)
        n = point.x
        m = px
      end
    end
    played = played_game(3, &game)
    assert_equal played[:m] + 2, played[:n], "the field does not hold the number px had on its line"
    refute_empty field_copies(&game), "the field keeps no copy, though a timer changes px"
  end

  # A field given its number just before a `loop do` keeps its copy, placed where it was given,
  # once the round that makes the `loop do` the game's is taken back and recorded again inside the
  # game's loop (Builder#take_round_since).
  def test_a_struct_field_given_before_a_loop_do_keeps_its_copy_through_the_loop
    game = proc do
      screen :bitmap
      px = 0
      n = 0
      game_loop do
        px = 5
        n = 0
        point = AnswerPoint.new(px + 2, 0, 0)
        loop do
          px += 1
          break if px > 8

          n += point.x
        end
      end
    end
    agrees("point = AnswerPoint.new(px + 2, ...); loop do px += 1; break if px > 8; n += point.x end",
           reads: %i[n px], passes: 3, &game)
    assert_equal 1, field_copies(&game).size, "the round taken back leaves no copy of its own behind"
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

  # A part's method a game loop calls, summing over the part's Array of Structs: the sum starts
  # afresh on every call, and adds every thing, as Ruby's does.
  def test_a_local_summed_over_a_walk_in_a_parts_method
    agrees("sum = 0; @points.each { sum += ... }; sum, in a method", reads: %i[m], passes: 2) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.total_x }
    end
  end

  # The same lines over a Ruby Array of the class's own stay Ruby's planning, worked out while
  # building.
  def test_a_local_summed_over_a_ruby_array_in_a_parts_method
    agrees("sum = 0; WEIGHTS.each { sum += ... }; sum, in a method", reads: %i[m], passes: 2) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.weight + filled.total_x }
    end
  end

  # The same sum over a walk through the part's own reader, or a local holding the Array: the
  # build reads either before the walk runs, so the sum agrees.
  def test_a_local_summed_over_a_walk_through_a_reader
    agrees("points.each { sum += ... }, in a method", reads: %i[m], passes: 2) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.total_x_by_reader }
    end
  end

  def test_a_local_summed_over_a_walk_through_a_local
    agrees("walked = @points; walked.each { sum += ... }, in a method", reads: %i[m], passes: 2) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.total_x_by_local }
    end
  end

  # Through a lambda handed with `&`, or a helper that yields, the build cannot tell what is
  # walked before it runs. A game walk would leave one item's number, so it is refused.

  def test_a_local_summed_by_a_lambda_over_a_walk_is_refused
    refused("@points.each(&add), add changing sum, in a method", /walk the Array by its instance variable/) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.total_x_by_lambda }
    end
  end

  def test_a_local_summed_through_a_helper_that_yields_is_refused
    refused("each_point { sum += ... }, in a method", /walk the Array by its instance variable/) do
      filled = AnswerFilled.new
      m = 0
      game_loop { m = filled.total_x_by_helper }
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

  def test_a_fraction_floored_in_its_class
    agrees("@x.floor after @x += 0.5", reads: %i[w], passes: 3) do
      fraction = AnswerFraction.new
      w = 0
      game_loop do
        fraction.step
        w = fraction.whole
      end
    end
  end

  def test_a_number_asked_a_verb_a_game_number_does_not_answer_is_refused
    refused("a.gcd(4)", /does not answer `gcd`/) do
      a = 3
      m = 0
      game_loop do
        a += 1
        m = a.gcd(4)
      end
    end
    refused("f.floor(1)", /`floor` with a number of digits/) do
      f = 0.5
      m = 0
      game_loop do
        f += 0.25
        m = f.floor(1)
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

  # A builder made by hand stays the thread's game after its game code stops with an error inside
  # an `if`; a part made after it is made once, not taken for one made on every pass of its loop.
  def test_part_made_after_a_builder_by_hand_stopped_inside_a_test
    builder = Builder.new
    stopping = VBlank::DSL::PlainRuby.rewrite(proc do
      k = 0
      game_loop do
        k += 1
        raise ArgumentError, "stopped inside a game test" if k > 2
      end
    end)
    assert_raises(ArgumentError) { builder.instance_eval(&stopping) }

    assert_kind_of AnswerTicker, AnswerTicker.new
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
    agrees("succ and pred", reads: %i[m n], passes: 3) do
      a = -2
      m = n = 0
      game_loop do
        a += 1
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
    # From 1.5 down by 0.75 a pass: 0.75, 0.0, -0.75, -1.5, -2.25, -3.0, so each sum takes in
    # halves, negatives and whole numbers, and round meets -1.5 (away from zero, -2).
    agrees("floor, ceil, round and truncate on a fraction", reads: %i[m n o p], passes: 6) do
      f = 1.5
      m = n = o = p = 0
      game_loop do
        f -= 0.75
        m += f.floor * 100 + 1000
        n += f.ceil * 100 + 1000
        o += f.round * 100 + 1000
        p += f.truncate * 100 + 1000
      end
    end
  end

  def test_rounding_a_whole_number
    agrees("floor, ceil, round, truncate on a whole number", reads: %i[m], passes: 2) do
      a = -3
      m = 0
      game_loop do
        a += 1
        m = a.floor + a.ceil + a.round + a.truncate
      end
    end
  end

  def test_power_and_divmod
    agrees("** and divmod", reads: %i[m n o q r s t], passes: 4) do
      a = -9
      m = n = o = q = r = s = t = 0
      game_loop do
        a += 4
        m = a**2
        n = a**3
        o = a.pow(0)
        q, r = a.divmod(4)
        s, t = a.divmod(-3)
      end
    end
  end

  def test_a_power_the_game_works_out_is_refused
    refused("2**a", /power/) do
      a = 3
      m = 0
      game_loop do
        a += 1
        m = 2**a
      end
    end
    refused("a**b", /power/) do
      a = 3
      b = 2
      m = 0
      game_loop do
        b += 1
        m = a**b
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

  # The names of the lists +program+ makes, in the order it makes them.
  # The hidden variables the build made to keep a Struct's field's number (Diagnostics::HiddenVariables).
  private def field_copies(&game)
    built = VBlank::Cartridge::EvaluatedGame.new(VBlank::DSL::PlainRuby.rewrite(game, checked: false))
    built.hidden_variable_notes.select { |note| note.why == :field }
  end

  private def list_names(node)
    own = node.kind == :list_new ? [node.name] : []
    own + node.children.flat_map { |child| list_names(child) }
  end

  # The game asking the EQUALITY_QUESTIONS case +name+ of game numbers each pass.
  private def equality_question(name)
    case name
    when "[a, b].uniq"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].uniq.size
        end
      end
    when "[1, 2].uniq { n + a }"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [1, 2].uniq { |i| i + a }.size
        end
      end
    when "[a, b].tally"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].tally.size
        end
      end
    when "[a, b].group_by"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].group_by { |i| i }.size
        end
      end
    when "[1, 2].group_by { n + a }"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [1, 2].group_by { |i| i + a }.size
        end
      end
    when "[a, b].index(7)"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].index(7)
        end
      end
    when "[a, b].find_index(7)"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].find_index(7)
        end
      end
    when "[a, b].rindex(7)"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].rindex(7)
        end
      end
    when "[1, 7].index(a)"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [1, 7].index(a)
        end
      end
    when "[a, b] - [7]"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = ([a, b] - [7]).size
        end
      end
    when "[a, b] & [7]"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = ([a, b] & [7]).size
        end
      end
    when "[a, b] | [7]"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = ([a, b] | [7]).size
        end
      end
    when "[1, 7] - [a]"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = ([1, 7] - [a]).size
        end
      end
    when "[a, b].difference([7])"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].difference([7]).size
        end
      end
    when "[a, b].intersection([7])"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].intersection([7]).size
        end
      end
    when "[a, b].union([7])"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].union([7]).size
        end
      end
    when "[a, b].intersect?([7])"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].intersect?([7]) ? 1 : 2
        end
      end
    when "[a, b].delete(7)"
      proc do
        a = 3
        b = 7
        n = 0
        game_loop do
          a += 1
          n = [a, b].delete(7)
        end
      end
    when "[p, q].index(q)", "[p, q].uniq", "[p, q] - [q]"
      struct_equality_question(name)
    when "sizes.counts.uniq"
      proc do
        sizes = AnswerNamedSizes.new
        n = 0
        game_loop do
          sizes.counts[0] += 1
          n = sizes.counts.uniq.size
        end
      end
    end
  end

  # The EQUALITY_QUESTIONS cases on a Ruby Array of two Structs, one with a field game code changes:
  # Ruby compares Structs by their fields.
  private def struct_equality_question(name)
    case name
    when "[p, q].index(q)"
      proc do
        p = AnswerPoint.new(1, 0, 0)
        q = AnswerPoint.new(2, 0, 0)
        n = 0
        game_loop do
          p.x += 1
          n = [p, q].index(q)
        end
      end
    when "[p, q].uniq"
      proc do
        p = AnswerPoint.new(1, 0, 0)
        q = AnswerPoint.new(2, 0, 0)
        n = 0
        game_loop do
          p.x += 1
          n = [p, q].uniq.size
        end
      end
    when "[p, q] - [q]"
      proc do
        p = AnswerPoint.new(1, 0, 0)
        q = AnswerPoint.new(2, 0, 0)
        n = 0
        game_loop do
          p.x += 1
          n = ([p, q] - [q]).size
        end
      end
    end
  end
end
