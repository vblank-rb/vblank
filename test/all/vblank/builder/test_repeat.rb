# frozen_string_literal: true

require "test_helper"

# repeat(n) { |i| } — the runtime counted loop. Assert its behavior: the body
# runs n times with the index counting 0..n-1, on the reference interpreter (the
# oracle) and on the console. The index is a Value, so it drives real positions.
#
# The Advance's cartridge drawing the marks in the emulator is in
# test/lowering/gba/vblank/builder/test_repeat_cartridge.rb.

# The game both files play.
module RepeatGames
  # One green 2px mark per iteration, spaced 4 apart (2 drawn, 2 gap) so the
  # marks stay discrete: column = i * 4. After repeat(n) there are marks at
  # x = 0, 4, ... 4*(n-1); the gaps and the absence past the last prove the count.
  private def marching_program(count)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      var :c, count
      repeat(:c) { |i| draw_rect_at i * 4, 40, 2, 2, :green }
      halt
    end
    builder.finalize_program
    builder.program
  end
end

class TestRepeat < Minitest::Test
  include VBlank::Console::Hardware
  include RepeatGames

  def test_interpreter_runs_the_body_once_per_index
    screen = game_player.run(marching_program(4)).screen

    # A mark at each of x = 0,4,8,12 (row 40)...
    [0, 4, 8, 12].each { |x| assert_equal Color.resolve(:green), screen.pixel(x, 40), "mark at x=#{x}" }
    assert_equal Color.resolve(:black), screen.pixel(2, 40), "a gap between marks"
    assert_equal Color.resolve(:black), screen.pixel(16, 40), "nothing past the last index"
  end

  def test_zero_count_runs_the_body_no_times
    screen = game_player.run(marching_program(0)).screen
    assert_equal Color.resolve(:black), screen.pixel(0, 40), "count 0 draws nothing"
  end

  def test_the_index_is_a_value_usable_in_expressions
    # column = i * 8, so marks land at x = 0, 8, 16 — i composes like any Value.
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      repeat(3) { |i| draw_rect_at i * 8, 40, 2, 2, :green }
      halt
    end
    builder.finalize_program
    screen = game_player.run(builder.program).screen

    [0, 8, 16].each { |x| assert_equal Color.resolve(:green), screen.pixel(x, 40), "mark at x=#{x}" }
    assert_equal Color.resolve(:black), screen.pixel(4, 40), "gap between the i*8 marks"
  end

  # Loops of sums and tests alone, which a lowering may count in whatever is quickest on its
  # processor: four deep, each index read in the innermost body.
  def test_loops_inside_loops_each_count_their_own_turns
    run = game_player.run(logic_program do
      total = var :total, 0
      turns = var :turns, 0
      game_loop do
        total = 0
        turns = 0
        repeat(3) do |a|
          repeat(4) do |b|
            repeat(2) do |c|
              repeat(5) do |d|
                total += a + (b << 2) + (c << 5) + (d << 7)
                turns += 1
              end
            end
          end
        end
      end
    end, frames: 2)
    sums = [0, 1, 2].product([0, 1, 2, 3], [0, 1], [0, 1, 2, 3, 4]).map { |a, b, c, d| a + (b << 2) + (c << 5) + (d << 7) }

    assert_equal 120, run[:turns]
    assert_equal sums.sum, run[:total]
  end

  def test_a_loop_reads_and_writes_lists_at_its_index_and_tests_it
    run = game_player.run(logic_program do
      squares = list :squares, capacity: 6, full_of: 0
      evens = var :evens, 0
      after = var :after, 0
      game_loop do
        evens = 0
        repeat(6) do |i|
          squares[i] = squares[i] + i + i + 1
          evens += 1 if (i & 1) == 0
        end
        after = squares[5] + evens
      end
    end, frames: 3)

    assert_equal [3, 9, 15, 21, 27, 33], run.list(:squares), "three passes of 2i + 1"
    assert_equal 36, run[:after]
  end

  # The count is worked out once, a count of nought or less makes no turn, and a loop that stops
  # early leaves what it counted to the statements after it.
  def test_a_count_the_game_keeps_is_read_once_and_nought_makes_no_turn
    run = game_player.run(logic_program do
      count = var :count, 5
      turns = var :turns, 0
      none = var :none, 0
      found = var :found, 0
      game_loop do
        turns = 0
        repeat(count) do
          turns += 1
          count = 2
        end
        repeat(none) { turns += 100 }
        repeat(20, stop_when: found == 7) { |i| found = i if i == 7 }
      end
    end, frames: 3)

    assert_equal 2, run[:turns], "five turns on the first pass, and two on each after it"
    assert_equal 7, run[:found]
  end

  private def logic_program(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end
end
