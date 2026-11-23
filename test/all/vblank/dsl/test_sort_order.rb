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

  private def screen_after(frames: 2, &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, checked: false))
    builder.finalize_program
    game_player.run(builder.program, frames: frames).screen
  end

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
