# frozen_string_literal: true

require "test_helper"

# A Ruby Array that game code changes is a game's own list (DSL::List), and one used only while
# building stays Ruby's. Each test plays a tiny game and reads what it leaves, on every lowering.
class TestPlainRubyArrays < Minitest::Test
  # Plays the block, rewritten, for +frames+ frames and hands back the player.
  private def played(frames: 3, &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  private def program_of(rewritten: true, &block)
    builder = Builder.new
    builder.instance_eval(&(rewritten ? VBlank::DSL::PlainRuby.rewrite(block) : block))
    builder.finalize_program
    builder.program
  end

  # The rewrite alone: an Array the game changes builds the program the same game written with
  # `list` builds, so every test of `list` holds for it.
  def test_an_array_builds_the_program_list_builds
    arrays = program_of do
      trail = Array.new(capacity: 4)
      ripple = Array.new(8, 0.0)
      game_loop do
        trail << 1
        ripple[2] = 0.5
      end
    end
    lists = program_of(rewritten: false) do
      trail = list :trail, capacity: 4
      ripple = list :ripple, capacity: 8, full_of: 0.0
      game_loop do
        trail << 1
        ripple[2] = 0.5
      end
    end

    assert_equal lists.walk.map(&:inspect), arrays.walk.map(&:inspect)
  end

  # The hero walks right 10 pixels a pass. The trail keeps its last four places, oldest first,
  # and each is drawn as a red dot on row 50.
  def test_a_trail_of_the_last_four_places_is_kept_and_drawn
    player = played(frames: 6) do
      screen :bitmap
      hero_x = 0
      trail = Array.new(capacity: 4)
      game_loop do
        clear_screen :black
        hero_x += 10
        trail.shift if trail.size == 4
        trail << hero_x
        trail.each { |place| draw_rect_at place, 50, 1, 1, :red }
      end
    end

    assert_equal [30, 40, 50, 60], player.list(:trail)
    [30, 40, 50, 60].each { |x| assert_equal Color.resolve(:red), player.screen.pixel(x, 50) }
    assert_equal Color.resolve(:black), player.screen.pixel(20, 50)
  end

  # Whether an Array holds fractions is read from what the game puts in it: here a fraction
  # variable, pushed after the line that reads the Array.
  def test_an_array_given_a_fraction_holds_fractions
    player = played(frames: 2) do
      speeds = Array.new(capacity: 8)
      vx = 0.5
      total = 0.0
      game_loop do
        total = speeds.first unless speeds.empty?
        vx += 0.25
        speeds << vx
      end
    end

    assert_equal [0.75, 1.0], player.list(:speeds)
    assert_in_delta 0.75, player[:total]
  end

  def test_an_array_given_a_worked_out_whole_number_and_a_fraction_is_refused_naming_both_lines
    error = assert_raises(ArgumentError) do
      played do
        speeds = Array.new(capacity: 8)
        vx = 0.5
        count = 0
        game_loop do
          vx += 0.25
          count += 1
          speeds << vx
          speeds << count
        end
      end
    end

    assert_match(/holds numbers with a fraction/, error.message)
    assert_equal 2, error.message.scan(/test_plain_ruby_arrays\.rb:\d+/).uniq.length, error.message
  end

  # Ruby's `Array.new(size, start)`: every item there from the start, a Float making them fractions.
  def test_an_array_made_full_holds_its_size_and_can_be_changed_at_any_item
    player = played(frames: 2) do
      ripple = Array.new(4, 0.0)
      at = 0
      game_loop do
        ripple[at] += 1.5
        at += 1
      end
    end

    assert_equal [1.5, 1.5, 0.0, 0.0], player.list(:ripple)
  end

  def test_an_array_written_out_and_changed_in_game_code_is_a_list
    player = played(frames: 2) do
      marks = [3, 1, 4]
      game_loop { marks[1] += 1 }
    end

    assert_equal [3, 3, 4], player.list(:marks)
  end

  # `shift` and `pop` hand back the item they drop, as Ruby's do; `first`, `last` and `empty?`
  # ask what is left.
  def test_shift_and_pop_hand_back_the_item_they_drop
    player = played(frames: 1) do
      queue = Array.new(capacity: 8)
      front = 0
      back = 0
      left = 0
      ends = 0
      game_loop do
        queue << 5
        queue.push 6
        queue << 7
        front = queue.shift
        back = queue.pop
        ends = queue.first + queue.last
        left = 1 unless queue.empty?
      end
    end

    assert_equal [5, 7, 12, 1, [6]], [player[:front], player[:back], player[:ends], player[:left], player.list(:queue)]
  end

  # An Array the game only reads, or one changed while building, is Ruby's own: no list is made.
  def test_an_array_used_only_while_building_stays_a_ruby_array
    player = played(frames: 1) do
      steps = [1, 2]
      steps << 3
      total = 0
      game_loop { total = steps[2] + steps.sum }
    end

    assert_equal 9, player[:total]
    assert_raises(StandardError) { player.list(:steps) }
  end

  # A Ruby loop in game code runs while building, so the pushes it makes with numbers known
  # then fill a Ruby Array: three rectangles laid out, on every pass.
  def test_an_array_filled_by_a_ruby_loop_in_game_code_stays_a_ruby_array
    player = played(frames: 1) do
      screen :bitmap
      game_loop do
        xs = []
        3.times { |n| xs << (n * 8) }
        xs.each { |x| draw_rect_at x, 10, 2, 2, :red }
      end
    end

    [0, 8, 16].each { |x| assert_equal Color.resolve(:red), player.screen.pixel(x, 10) }
  end

  # The item `shift` drops comes back where a branch's last line is the answer.
  def test_shift_hands_back_its_item_as_the_answer_of_a_branch
    player = played(frames: 1) do
      queue = [5, 6, 7]
      taken = 0
      second = 0
      game_loop do
        taken = queue.empty? ? 0 : queue.shift
        second = if queue.empty?
                   0
                 else
                   queue.pop
                 end
      end
    end

    assert_equal [5, 7, [6]], [player[:taken], player[:second], player.list(:queue)]
  end

  def test_a_list_named_as_an_array_is_refused_naming_both_lines
    error = assert_raises(ArgumentError) do
      played do
        trail = Array.new(capacity: 4)
        list :trail, capacity: 2
        game_loop { trail << 1 }
      end
    end

    assert_match(/`trail`/, error.message)
    assert_equal 2, error.message.scan(/test_plain_ruby_arrays\.rb:\d+/).uniq.length, error.message
  end

  def test_an_array_named_as_a_list_is_refused_naming_both_lines
    error = assert_raises(ArgumentError) do
      played do
        list :trail, capacity: 2
        trail = Array.new(capacity: 4)
        game_loop { trail << 1 }
      end
    end

    assert_equal 2, error.message.scan(/test_plain_ruby_arrays\.rb:\d+/).uniq.length, error.message
  end

  # Ruby copies a number into an Array, so changing the item leaves the local it came from alone,
  # though game code changes that local too. After five passes `a` is still 1 and `pair[0]` is 6:
  # a red dot at 1 and a green one at 6.
  def test_changing_an_item_made_from_a_local_leaves_the_local_alone
    player = played(frames: 5) do
      screen :bitmap
      a = 1
      b = 1
      pair = [a, b]
      game_loop do
        pair[0] += 1
        a += 0 if a > 100
        clear_screen :black
        draw_rect_at a, 10, 1, 1, :red
        draw_rect_at pair[0], 20, 1, 1, :green
      end
    end

    assert_equal [6, 1], player.list(:pair)
    assert_equal Color.resolve(:red), player.screen.pixel(1, 10)
    assert_equal Color.resolve(:green), player.screen.pixel(6, 20)
    assert_equal Color.resolve(:black), player.screen.pixel(6, 10)
  end

  # A local beside a `var` handle is copied as well: the Array is a list of their numbers.
  def test_an_array_of_a_local_and_a_var_handle_is_a_list_of_their_numbers
    player = played(frames: 1) do
      a = 1
      pair = [a, var(:second, 2)]
      game_loop do
        pair[1] += 3
        a += 0 if a > 100
      end
    end

    assert_equal [2, [1, 5]], [player[:second], player.list(:pair)]
  end

  # An Array made only of `var` handles is an Array of places, as one of sprites is: a write to
  # an item changes that variable.
  def test_an_array_of_var_handles_stays_an_array_of_variables
    player = played(frames: 1) do
      shown = Array.new(2) { |n| var :"shown#{n}", 0 }
      pair = [var(:first, 1), var(:second, 1)]
      game_loop do
        shown[1] = 4
        pair[0] += 2
      end
    end

    assert_equal [0, 4, 3], [player[:shown0], player[:shown1], player[:first]]
  end

  def test_an_array_the_game_pushes_to_with_no_capacity_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        trail = []
        game_loop { trail << 1 }
      end
    end

    assert_match(/capacity:/, error.message)
    assert_match(/test_plain_ruby_arrays\.rb:\d+/, error.message)
  end

  def test_a_full_array_the_game_pushes_to_with_no_capacity_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        trail = Array.new(4, 0)
        game_loop { trail.push 1 }
      end
    end

    assert_match(/capacity:/, error.message)
  end

  def test_a_capacity_the_game_works_out_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        room = 4
        game_loop do
          room += 1
          trail = Array.new(capacity: room)
          trail << 1
        end
      end
    end

    assert_match(/the build\s+must know the capacity/, error.message)
  end

  def test_an_array_made_with_a_size_and_no_start_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        slots = Array.new(8)
        game_loop { slots[0] = 1 }
      end
    end

    assert_match(/give the number each item starts as/, error.message)
  end

  def test_an_array_of_arrays_the_game_changes_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        rows = [[0, 0], [0, 0]]
        game_loop { rows[0] = 1 }
      end
    end

    assert_match(/holds numbers only/, error.message)
  end

  def test_a_setting_a_list_does_not_take_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played do
        trail = Array.new(capacity: 4, of: 0)
        game_loop { trail << 1 }
      end
    end

    assert_match(/does not take `of:`/, error.message)
  end

  def test_an_array_method_a_list_does_not_have_is_refused_by_name
    error = assert_raises(NoMethodError) do
      played do
        marks = [3, 1, 4]
        game_loop { marks.rotate! }
      end
    end

    assert_match(/`rotate!` is a method of a Ruby Array/, error.message)
    assert_match(/`shift`/, error.message)
  end

  # `unshift` adds an item, but at the front, which a list cannot do: it is refused by name, not
  # taken for a push that needs room.
  def test_unshift_is_refused_by_name
    error = assert_raises(NoMethodError) do
      played do
        marks = Array.new(capacity: 4)
        game_loop { marks.unshift 1.5 }
      end
    end

    assert_match(/`unshift` is a method of a Ruby Array/, error.message)
  end

  # `marks[0] += 10 if ...` under a test the game makes changes the item on the passes the test
  # holds, as Ruby does.
  def test_an_item_changed_under_a_game_test
    player = played(frames: 3) do
      marks = [3, 1, 4]
      passes = 0
      game_loop do
        passes += 1
        marks[0] += 10 if passes == 2
      end
    end

    assert_equal [13, 1, 4], player.list(:marks)
  end

  # Ruby's questions about an Array written out of game numbers, which stays Ruby's, each asked
  # with the items both ways round: the game works out Ruby's answer as it plays.
  def test_questions_about_an_array_of_game_numbers_give_rubys_answers
    player = played(frames: 1) do
      a = 3
      b = 7
      big = 0
      big_back = 0
      small = 0
      small_back = 0
      low = 0
      high = 0
      over_five = 0
      some = 0
      every = 0
      no_ten = 0
      has_seven = 0
      game_loop do
        a += 0
        b += 0
        big = [a, b].max
        big_back = [b, a].max
        small = [a, b].min
        small_back = [b, a].min
        low, high = [b, a].minmax
        over_five = [a, b].count { |n| n > 5 }
        some = 1 if [a, b].any? { |n| n > 5 }
        every = 1 if [a, b].all? { |n| n > 5 }
        no_ten = 1 if [a, b].none? { |n| n > 10 }
        has_seven = 1 if [a, b].include?(7)
      end
    end

    assert_equal [7, 7, 3, 3, 3, 7, 1, 1, 0, 1, 1],
                 %i[big big_back small small_back low high over_five some every no_ten has_seven].map { |name| player[name] }
  end

  # A Ruby question whose block makes a test the game decides as it plays, where Ruby needs the
  # answer while building, is refused rather than answered wrong.
  def test_a_block_test_ruby_needs_while_building_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        a = 3
        b = 7
        first = 0
        game_loop do
          a += 1
          first = [a, b].find { |n| n > 5 }
        end
      end
    end

    assert_match(/`find`/, error.message)
  end

  # Ruby sorts and compares with `<=>`, which needs its answer while building.
  def test_comparing_game_numbers_with_the_spaceship_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        a = 3
        b = 7
        first = 0
        game_loop do
          a += 1
          first = [b, a].sort.first
        end
      end
    end

    assert_match(/`<=>`/, error.message)
  end

  # `<=>` written in game code with a game number on a side is a game number, -1, 0 or 1, as
  # Ruby's: here against numbers below, level with and above it, negatives too, both ways round,
  # and Arrays of them, the first items deciding and the next breaking the ties.
  def test_the_spaceship_written_out_gives_rubys_answer
    player = played(frames: 1) do
      a = -3
      below = 9
      level = 9
      above = 9
      flipped = 9
      first_decides = 9
      tie_broken = 9
      all_level = 9
      game_loop do
        a += 0
        below = a <=> -7
        level = a <=> -3
        above = a <=> 2
        flipped = 2 <=> a
        first_decides = [a, 5] <=> [-4, 9]
        tie_broken = [a, 5] <=> [-3, 9]
        all_level = [a, 5] <=> [-3, 5]
      end
    end

    names = %i[below level above flipped first_decides tie_broken all_level]
    assert_equal [1, 0, -1, 1, 1, -1, 0], names.map { |name| player[name] }
  end

  # Ruby's `clamp` and `max_by` ask `<=>` while building, which a game number cannot answer.
  def test_the_spaceship_asked_by_clamp_or_max_by_is_refused
    clamped = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        a = 3
        kept = 0
        game_loop do
          a += 1
          kept = 9.clamp(a, 20)
        end
      end
    end
    picked = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        a = 3
        kept = 0
        game_loop do
          a += 1
          kept = [a, 7].max_by { |n| n }
        end
      end
    end

    [clamped, picked].each { |error| assert_match(/`<=>`/, error.message) }
  end

  # `<=>` asked by Ruby code the rewrite never reads (a helper of the game's in a plain file, a
  # gem) is refused too: only making a Range gets an answer.
  def test_the_spaceship_asked_by_any_other_ruby_code_is_refused
    ordered = ->(x, y) { x <=> y } # written outside the game block, so never rewritten
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        a = 3
        kept = 0
        game_loop do
          a += 1
          kept = ordered.call(a, 7)
        end
      end
    end

    assert_match(/`<=>`/, error.message)
  end

  # A Range made of game numbers still builds: Ruby asks its ends `<=>` to make it.
  def test_a_range_of_game_numbers_still_builds
    player = played(frames: 1) do
      low = 2
      high = 9
      kept = 0
      game_loop do
        low += 1
        high += 1
        span = (low..high)
        kept = span.end - span.begin
      end
    end

    assert_equal 7, player[:kept]
  end

  # A high-score table, sorted each pass as Ruby sorts it: the smallest first, the biggest first
  # by a comparison or a key, and with `reverse!` after the sort. A new score goes in each pass,
  # so the sort has work every time.
  def test_sort_puts_an_array_in_order_as_ruby_does
    player = played(frames: 2) do
      up = [7, 3, 9, 3, 1]
      down = [7, 3, 9, 3, 1]
      by_key = [7, 3, 9, 3, 1]
      turned = [7, 3, 9, 3, 1]
      game_loop do
        up.sort!
        down.sort! { |a, b| b <=> a }
        by_key.sort_by! { |n| -n }
        turned.sort!.reverse!
      end
    end

    assert_equal [1, 3, 3, 7, 9], player.list(:up)
    assert_equal [9, 7, 3, 3, 1], player.list(:down)
    assert_equal [9, 7, 3, 3, 1], player.list(:by_key)
    assert_equal [9, 7, 3, 3, 1], player.list(:turned)
  end

  # Items the game works out as it plays, shifted round a ring first, sorted with fractions.
  def test_sort_orders_fractions_in_a_ring
    player = played(frames: 5) do
      speeds = Array.new(capacity: 4)
      t = 0
      game_loop do
        t += 1
        speeds.shift if speeds.size == 4
        speeds << (((t * 3) % 5).to_f + 0.5)
        speeds.sort!
      end
    end

    # 3.5, 1.5, 4.5 and 2.5 in, sorted; then the smallest, 1.5, shifted out for 0.5.
    assert_equal [0.5, 2.5, 3.5, 4.5], player.list(:speeds)
  end

  def test_sort_with_a_block_comparing_another_way_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        marks = [3, 1, 4]
        game_loop { marks.sort! { |a, b| (a <=> b) * 2 } }
      end
    end

    assert_match(/sorts by a number/, error.message)
  end

  def test_sort_making_a_new_array_is_refused_naming_sort_with_a_bang
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        marks = [3, 1, 4]
        game_loop do
          marks[0] = 2
          marks.sort
        end
      end
    end

    assert_match(/`sort!`/, error.message)
  end
end
