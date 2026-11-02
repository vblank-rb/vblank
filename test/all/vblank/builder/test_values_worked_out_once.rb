# frozen_string_literal: true

require "test_helper"

# A VALUE WORKED OUT BEFORE A VARIABLE CHANGES KEEPS WHAT IT WAS THEN. `sum = a + b` reads as a line
# that happens now, whatever the line after it does to `b`, on every lowering.
class TestValuesWorkedOutOnce < Minitest::Test
  private def played(&lines)
    b = Builder.new
    b.instance_eval(&lines)
    b.finalize_program
    game_player.run(b.program, frames: 3)
  end

  def test_a_sum_keeps_what_it_was_when_its_variable_changes
    run = played do
      fact = var :fact, 97
      first = var :first, 0
      seen = var :seen, 0
      once = var :once, 0
      game_loop do
        if once == 0
          once = 1
          sum = fact + first
          first += 1
          seen = sum
        end
      end
    end

    assert_equal 97, run[:seen]
  end

  def test_a_difference_keeps_what_it_was_when_its_variable_changes
    run = played do
      fact = var :fact, 97
      first = var :first, 0
      seen = var :seen, 0
      once = var :once, 0
      game_loop do
        if once == 0
          once = 1
          difference = fact - first
          first += 1
          seen = difference
        end
      end
    end

    assert_equal 97, run[:seen]
  end

  # The shape a game met: a number written first, one local name for two jobs, and a line of its own
  # inside an `if` with a test of several parts.
  def test_a_written_number_first_keeps_what_it_was
    run = played do
      first = var :first, 0
      column = var :column, 0
      row = var :row, 0
      tick = var :tick, 0
      other = var :other, 0
      game_loop do
        tick += 1
        repeat(other) do |i|
          burnt = 97 + i
          column = burnt % 32
        end
        if tick % 2 == 0 && first < 3
          burnt = 97 + first
          first += 1
          column = burnt % 32
          row = burnt / 32
        end
      end
    end

    assert_equal [1, 3], [run[:column], run[:row]]
  end

  # One name for two jobs, each in an `if` of its own, in a block the game runs every pass.
  def test_a_name_written_in_two_ifs_keeps_what_it_was_each_time
    run = played do
      first = var :first, 0
      second = var :second, 0
      column = var :column, 0
      column_two = var :column_two, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        if tick == 2
          burnt = 97 + first
          first += 1
          column = burnt % 32
        end
        if tick == 2
          burnt = 97 - second
          second += 1
          column_two = burnt % 32
        end
      end
    end

    assert_equal [1, 1], [run[:column], run[:column_two]]
  end

  # A number read out of a Ruby hash on the way: the variable the sum reads sits behind a call.
  def test_a_sum_with_a_hash_read_first_keeps_what_it_was
    run = played do
      facts = { cell: 97 }
      first = var :first, 0
      column = var :column, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        if tick == 2
          burnt = facts[:cell] + first
          first += 1
          column = burnt % 32
        end
      end
    end

    assert_equal 1, run[:column]
  end

  # The same read as the place a cell changes at, which is where a game met it.
  def test_a_changed_cell_lands_where_the_value_was
    bar = nil
    run = played do
      screen :tiled
      image(:sky, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:mark, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "." => :sky, "x" => :mark
      bar = background :bar, tiles: :set, map: Array.new(8) { "." * 32 }
      facts = { cell: 97 }
      first = var :first, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        if tick == 2 && first < 3
          burnt = facts[:cell] + first
          first += 1
          bar.set_tile burnt % 32, burnt / 32, "x"
        end
      end
    end

    assert_equal VBlank::Graphics::Color.resolve(:red), run.screen.pixel(1 * 8, 3 * 8), "the cell asked for"
    assert_equal VBlank::Graphics::Color.resolve(:blue), run.screen.pixel(2 * 8, 3 * 8), "the cell after it"
  end

  # The game variables made by plain lines, `first = 0`, and changed from blocks further in, inside a
  # scene as a game's are, with the name also used in a `repeat` and set back elsewhere.
  def test_plain_variables_changed_from_inner_blocks_keep_what_they_were
    run = played do
      facts = { cell: 97 }
      first = 0
      column = var :column, 0
      tick = 0
      var :state, 0
      scene(:stage) do
        repeat(first) do |i|
          burnt = facts[:cell] + i
          column = burnt % 32
        end
        first = 0 if tick == 50
        tick += 1
        if tick % 2 == 0 && first < 3
          burnt = facts[:cell] + first
          first += 1
          column = burnt % 32
        end
      end
      game_loop do
        case_var(:state) { when_val 0, :stage }
      end
    end

    assert_equal 1, run[:column]
  end

  # The shape the game met, whole: the name's later read, in the next `if`, makes the first `if`'s
  # write a name that lasts beyond it, and that write is the one that has to keep its answer.
  def test_a_name_read_again_in_a_later_if_keeps_what_it_was
    run = played do
      facts = { cell: 97 }
      first = 0
      second = 0
      column = var :column, 0
      column_two = var :column_two, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        if tick % 2 == 0 && first < 3
          burnt = facts[:cell] + first
          first += 1
          column = burnt % 32
        end
        if tick % 2 == 0 && second < 3
          burnt = facts[:cell] - second
          second += 1
          column_two = burnt % 32
        end
      end
    end

    assert_equal [1, 1], [run[:column], run[:column_two]]
  end

  # ...and all of it under a test the game makes, as the game's is.
  def test_a_name_read_again_in_a_later_if_under_another_if_keeps_what_it_was
    run = played do
      facts = { cell: 97 }
      first = 0
      second = 0
      column = var :column, 0
      column_two = var :column_two, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        if tick >= 2
          if tick % 2 == 0 && first < 3
            burnt = facts[:cell] + first
            first += 1
            column = burnt % 32
          end
          if tick % 2 == 0 && second < 3
            burnt = facts[:cell] - second
            second += 1
            column_two = burnt % 32
          end
        end
      end
    end

    assert_equal [1, 1], [run[:column], run[:column_two]]
  end

  def test_a_value_used_as_a_place_keeps_what_it_was
    run = played do
      fact = var :fact, 97
      first = var :first, 0
      column = var :column, 0
      once = var :once, 0
      game_loop do
        if once == 0
          once = 1
          burnt = fact + first
          first += 1
          column = burnt % 32
        end
      end
    end

    assert_equal 1, run[:column]
  end
end
