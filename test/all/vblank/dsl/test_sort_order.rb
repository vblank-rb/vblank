# frozen_string_literal: true

require "test_helper"

# A sorted Array drawn on the screen, row by row, matches the order Ruby sorts it in. Each item
# is a bar as long as its number, so a bar's end shows which item stands in that row.
class TestSortOrder < Minitest::Test
  Spot = Struct.new(:x, :y)

  # Spots that say their own order the Ruby way: by y, by y the biggest first, by y and then x.
  Low = Struct.new(:x, :y) do
    include Comparable

    def <=>(other) = y <=> other.y
  end

  High = Struct.new(:x, :y) do
    include Comparable

    def <=>(other) = other.y <=> y
  end

  Tied = Struct.new(:x, :y) do
    include Comparable

    def <=>(other) = [y, x] <=> [other.y, other.x]
  end

  # An order that is not one field after another: the build cannot sort by it.
  Summed = Struct.new(:x, :y) do
    include Comparable

    def <=>(other) = (x + y) <=> (other.x + other.y)
  end

  STARTS = [[30, 2], [10, 1], [50, 2], [20, 1], [40, 0]].freeze

  private def ruby_order(kind) = STARTS.map { |x, y| kind.new(x, y) }.sort.map(&:x)

  # The things are made from STARTS on the first pass, sorted with `sort!` each pass and drawn
  # as bars of their x. A Struct is named in each game block, which is how the build tells an
  # Array of Structs.
  def test_a_struct_ordered_by_one_field_sorts_as_ruby_does
    starts = STARTS
    screen = screen_after do
      spots = Array.new(capacity: 5)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Low.new(x, y) }
          started = 1
        end
        spots.sort!
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    assert_equal ruby_order(Low), bar_lengths(screen, 5)
  end

  def test_a_struct_ordered_by_one_field_the_biggest_first_sorts_as_ruby_does
    starts = STARTS
    screen = screen_after do
      spots = Array.new(capacity: 5)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << High.new(x, y) }
          started = 1
        end
        spots.sort!
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    assert_equal ruby_order(High), bar_lengths(screen, 5)
  end

  def test_a_struct_ordered_by_two_fields_sorts_as_ruby_does
    starts = STARTS
    screen = screen_after do
      spots = Array.new(capacity: 5)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Tied.new(x, y) }
          started = 1
        end
        spots.sort!
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    assert_equal ruby_order(Tied), bar_lengths(screen, 5)
  end

  # `min`, `max` and `minmax` hand back the things the Struct's order puts first and last; with
  # ties by y, Tied's x decides.
  def test_min_max_and_minmax_follow_the_structs_own_order
    starts = STARTS
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 5)
      started = 0
      low_x = 0
      high_x = 0
      pair_low_x = 0
      pair_high_x = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Tied.new(x, y) }
          started = 1
        end
        low_x = spots.min.x
        high_x = spots.max.x
        low, high = spots.minmax
        pair_low_x = low.x
        pair_high_x = high.x
      end
    end, frames: 2)

    sorted = STARTS.map { |x, y| Tied.new(x, y) }.sort.map(&:x)
    assert_equal [sorted.first, sorted.last, sorted.first, sorted.last],
                 %i[low_x high_x pair_low_x pair_high_x].map { |name| player[name] }
  end

  # Two things compared with `<`, `>`, `<=`, `>=`, `between?`, `clamp` and Comparable's `==`
  # answer as Ruby's Comparable does by the Struct's `<=>`: each answer is a bit of `bits`. Low
  # orders by y alone, so (30, 2) and (50, 2) are level, and `==` holds for them as Ruby's does.
  def test_things_compare_as_comparable_says
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 3)
      started = 0
      bits = 0
      clamped_x = 0
      game_loop do
        if started == 0
          [[30, 2], [50, 2], [10, 1]].each { |x, y| spots << Low.new(x, y) }
          started = 1
        end
        bits = 0
        low = spots.min
        high = spots.max
        spots.each do |s|
          bits *= 2
          bits += 1 if s < high
          bits *= 2
          bits += 1 if s > low
          bits *= 2
          bits += 1 if s <= low
          bits *= 2
          bits += 1 if s >= high
          bits *= 2
          bits += 1 if s.between?(low, high)
          bits *= 2
          bits += 1 if s == high
        end
        clamped_x = spots.min.clamp(high, high).x
      end
    end, frames: 2)

    things = [[30, 2], [50, 2], [10, 1]].map { |x, y| Low.new(x, y) }
    low = things.min
    high = things.max
    ruby_bits = things.reduce(0) do |bits, s|
      [s < high, s > low, s <= low, s >= high, s.between?(low, high), s == high].reduce(bits) do |all, bit|
        (all * 2) + (bit ? 1 : 0)
      end
    end
    assert_equal [ruby_bits, low.clamp(high, high).x], [player[:bits], player[:clamped_x]]
  end

  # A comparing block given to `sort!`, `min` or `max` orders by itself, as in Ruby, not by the
  # Struct's own `<=>`. The blocks are the form under test, so the cop's `max_by` does not apply.
  # rubocop:disable Performance/CompareWithBlock
  def test_a_comparing_block_orders_instead_of_the_structs_own
    starts = STARTS
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 5)
      started = 0
      first_x = 0
      biggest_x = 0
      smallest_x = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Low.new(x, y) }
          started = 1
        end
        spots.sort! { |p, q| q.y <=> p.y }
        first_x = 0
        spots.each_with_index { |s, at| first_x = s.x if at == 0 }
        biggest_x = spots.max { |p, q| p.x <=> q.x }.x
        smallest_x = spots.min { |p, q| p.x <=> q.x }.x
      end
    end, frames: 2)

    things = STARTS.map { |x, y| Low.new(x, y) }
    ruby = [things.sort { |p, q| q.y <=> p.y }.first.x, things.max { |p, q| p.x <=> q.x }.x,
            things.min { |p, q| p.x <=> q.x }.x]
    assert_equal ruby, %i[first_x biggest_x smallest_x].map { |name| player[name] }
  end
  # rubocop:enable Performance/CompareWithBlock

  def test_min_or_max_of_a_count_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built_program do
        spots = Array.new(capacity: 3)
        game_loop do
          spots << Low.new(1, 2) if spots.empty?
          spots.min(2)
        end
      end
    end

    assert_match(/`min\(2\)`/, error.message)
  end

  # `eql?` stays Struct's, every field, as Ruby's Comparable defines none: two things level by y
  # alone are `==` and not `eql?`.
  def test_eql_compares_every_field
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 2)
      started = 0
      equal = 0
      eql = 0
      game_loop do
        if started == 0
          spots << Low.new(1, 2)
          spots << Low.new(3, 2)
          started = 1
        end
        first = spots.min
        equal = 0
        eql = 0
        spots.each do |s|
          equal += 1 if s == first
          eql += 1 if s.eql?(first)
        end
      end
    end, frames: 2)

    assert_equal [2, 1], [player[:equal], player[:eql]]
  end

  Counted = Struct.new(:x, :y, :n) do
    include Comparable

    def <=>(other)
      self.n += 1
      y <=> other.y
    end
  end

  def test_a_struct_order_that_changes_something_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built_program do
        spots = Array.new(capacity: 3)
        game_loop do
          spots << Counted.new(1, 2, 0) if spots.empty?
          spots.sort!
        end
      end
    end

    assert_match(/`<=>`/, error.message)
  end

  # Ruby's `clamp` stops with an error where min comes after max, which the game cannot tell
  # while building: refused, unless min and max are one thing.
  def test_clamp_between_two_things_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built_program do
        spots = Array.new(capacity: 3)
        kept = 0
        game_loop do
          spots << Low.new(1, 2) if spots.empty?
          kept = spots.min.clamp(spots.max, spots.min).x
        end
      end
    end

    assert_match(/`clamp`/, error.message)
  end

  def test_comparing_a_thing_of_another_array_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built_program do
        spots = Array.new(capacity: 3)
        others = Array.new(capacity: 3)
        seen = 0
        game_loop do
          spots << Low.new(1, 2) if spots.empty?
          others << Low.new(1, 2) if others.empty?
          seen += 1 if spots.min < others.min
        end
      end
    end

    assert_match(/another Array/, error.message)
  end

  # `min` of an empty Array is nil in Ruby, so `if (m = spots.min)` does not run: the thing it
  # hands back is a test that the Array was not empty.
  def test_min_of_an_empty_array_is_false_as_a_test
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 3)
      runs = 0
      game_loop do
        spots << Low.new(1, 2)
        spots.clear
        runs += 1 if spots.min
        runs += 10 if (smallest = spots.max)
        runs += 100 unless smallest
      end
    end, frames: 2)

    # The two tests never hold, and the `unless` does on each of the two passes.
    assert_equal 200, player[:runs]
  end

  def test_min_in_a_routine_a_walk_may_call_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      built_program do
        spots = Array.new(capacity: 3)
        smallest = 0
        func :smallest_x do
          smallest = spots.min.x
        end
        game_loop do
          spots << Low.new(1, 2) if spots.empty?
          spots.each { |_s| call :smallest_x }
        end
      end
    end

    assert_match(/routine/, error.message)
  end

  Unordered = Struct.new(:x, :y) do
    include Comparable
  end

  # Comparable with no `<=>` of its own: Ruby's `==` is then the same thing only.
  def test_comparable_with_no_order_is_equal_only_to_itself
    player = game_player
    player.run(built_program do
      spots = Array.new(capacity: 2)
      started = 0
      equal = 0
      game_loop do
        if started == 0
          spots << Unordered.new(1, 2)
          spots << Unordered.new(1, 2)
          started = 1
        end
        pick = nil
        spots.each { |s| pick = s if s.x == 1 }
        equal = 0
        spots.each { |s| equal += 1 if s == pick }
      end
    end, frames: 2)

    # Both things hold the same fields, and only the one picked, the second, is == to it.
    assert_equal 1, player[:equal]
  end

  def test_a_struct_order_that_is_not_fields_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      screen_after do
        spots = Array.new(capacity: 5)
        game_loop do
          spots << Summed.new(1, 2) if spots.empty?
          spots.sort!
        end
      end
    end

    assert_match(/`<=>`/, error.message)
  end

  private def built_program(&block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, checked: false))
    builder.finalize_program
    builder.program
  end

  private def screen_after(frames: 2, &block) = game_player.run(built_program(&block), frames: frames).screen

  # The length of the bar in each of +rows+ rows, 10 pixels apart from y = 10.
  private def bar_lengths(screen, rows)
    Array.new(rows) do |row|
      y = 10 + (row * 10)
      (0...240).count { |x| screen.pixel(x, y) == Color.resolve(:yellow) }
    end
  end

  def test_sorted_scores_are_drawn_in_rubys_order
    screen = screen_after do
      scores = [30, 10, 50, 20, 40]
      game_loop do
        scores[0] += 1 if pressed(:a)
        scores.sort! { |a, b| b <=> a }
        clear_screen :black
        scores.each_with_index { |score, at| draw_rect_at 0, 10 + (at * 10), score, 4, :yellow }
      end
    end

    assert_equal [30, 10, 50, 20, 40].sort.reverse, bar_lengths(screen, 5)
  end

  # Sorted by y, and where two share a y, by x the biggest first: a key of two fields.
  def test_sorted_structs_are_drawn_in_rubys_order_by_a_key_of_two_fields
    starts = [[30, 2], [10, 1], [50, 2], [20, 1], [40, 0]]
    screen = screen_after do
      spots = Array.new(capacity: 5)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Spot.new(x, y) }
          started = 1
        end
        spots.sort_by! { |s| [s.y, -s.x] }
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    ruby = starts.map { |x, y| Spot.new(x, y) }.sort_by { |s| [s.y, -s.x] }.map(&:x)
    assert_equal ruby, bar_lengths(screen, 5)
  end

  # The same key the other way round, with `reverse!`.
  def test_a_key_of_two_fields_reversed
    starts = [[30, 2], [10, 1], [50, 2], [20, 1], [40, 0]]
    screen = screen_after do
      spots = Array.new(capacity: 5)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Spot.new(x, y) }
          started = 1
        end
        spots.sort_by! { |s| [s.y, s.x] }.reverse!
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    ruby = starts.map { |x, y| Spot.new(x, y) }.sort_by { |s| [s.y, s.x] }.reverse.map(&:x)
    assert_equal ruby, bar_lengths(screen, 5)
  end

  # Two sorts of one Array on one line, by different keys: each sorts by its own.
  def test_two_sorts_on_one_line_each_sort_by_their_own_key
    starts = [[30, 10], [10, 30], [20, 20]]
    screen = screen_after do
      spots = Array.new(capacity: 3)
      started = 0
      game_loop do
        if started == 0
          starts.each { |x, y| spots << Spot.new(x, y) }
          started = 1
        end
        spots.sort_by! { |s| -s.y }; spots.sort_by! { |s| -s.x } # rubocop:disable Style/Semicolon
        clear_screen :black
        spots.each_with_index { |s, at| draw_rect_at 0, 10 + (at * 10), s.x, 4, :yellow }
      end
    end

    assert_equal [30, 20, 10], bar_lengths(screen, 3)
  end

  # A sort in a routine that a walk of the same Array calls would move the walk's place.
  def test_a_sort_in_a_routine_called_during_a_walk_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      screen_after do
        spots = Array.new(capacity: 3)
        seen = 0
        func :order do
          spots.sort_by! { |s| s.y }
        end
        game_loop do
          spots << Spot.new(1, 2) if spots.empty?
          seen = 0
          spots.each do |s|
            seen += s.x
            call :order if s.x == 1
          end
        end
      end
    end

    assert_match(/walk/, error.message)
  end

  # `reverse!` moves its sort to the routine with the key turned round, and the routine it left,
  # which nothing calls, is not built at all.
  def test_reverse_leaves_no_routine_that_nothing_calls
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      marks = [3, 1, 4]
      game_loop do
        marks[0] += 1 if pressed(:a)
        marks.sort!.reverse!
      end
    end))
    sorts = builder.declared_function_names.grep(/\A__sort_/)

    assert_equal 1, sorts.size
    assert_match(/item_down\z/, sorts.first.to_s)
  end

  def test_a_key_of_two_numbers_on_an_array_of_numbers_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      screen_after do
        marks = [3, 1, 4]
        game_loop do
          marks[0] += 1 if pressed(:a)
          marks.sort_by! { |n| [n, -n] }
        end
      end
    end

    assert_match(/sorts by one number/, error.message)
  end
end
