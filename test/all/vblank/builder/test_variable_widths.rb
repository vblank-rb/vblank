# frozen_string_literal: true

require "test_helper"

# A VARIABLE KEPT A BYTE OR TWO WIDE holds what a list's slot of that width holds: the low bits, read
# back with their sign. What it holds is the same on every lowering; only what a console pays for
# it differs (test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_variable_widths.rb).
class TestVariableWidths < Minitest::Test
  private def played(&game)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_eval(&game)
      game_loop { wait_vblank }
    end
    b.finalize_program
    game_player.run(b.program, frames: 3)
  end

  def test_a_byte_wraps_with_its_sign_as_a_list_slot_does
    run = played do
      x = var :x, 100, width: :byte
      x += 100
      copy_of = var :copy_of, 0
      copy_of = x
      y = var :y, 200 - 73, width: :byte
      y += 1
    end

    assert_equal(-56, run[:x], "100 + 100 kept in a byte")
    assert_equal(-56, run[:copy_of], "and read back whole")
    assert_equal(-128, run[:y], "127 + 1")
  end

  def test_a_half_wraps_with_its_sign
    run = played do
      x = var :x, 30_000, width: :half
      y = var :y, 10_000, width: :half
      x += y
    end

    assert_equal(-25_536, run[:x])
  end

  # Every way of changing a variable, under an `if` and its `else` as well as at the top.
  def test_every_change_of_a_kept_variable_wraps
    run = played do
      var :lowest, -128, width: :byte
      negate! :lowest
      var :other, -128, width: :byte
      abs! :other
      taken = var :taken, -128, width: :byte
      n = var :n, 1
      if n == 1
        taken -= 1
      end
      summed = var :summed, 0, width: :byte
      if n == 2
        summed = 1
      else
        summed = n + 127
      end
    end

    assert_equal(-128, run[:lowest], "128 has no place in a byte")
    assert_equal(-128, run[:other])
    assert_equal(127, run[:taken], "-128 - 1")
    assert_equal(-128, run[:summed], "worked out in the else")
  end

  def test_a_kept_variable_reads_and_compares_as_its_number
    run = played do
      x = var :x, -3, width: :byte
      y = var :y, -300, width: :half
      seen = var :seen, 0
      seen += 1 if x == -3
      seen += 2 if x < 0
      seen += 4 if x < 5
      seen += 8 if x > -4
      seen += 16 if y < x
      seen += 32 if y == -300
      seen += 64 if y >= 0
      seen += 128 if x + y == -303
      seen += 256 if x != 253
    end

    assert_equal 1 + 2 + 4 + 8 + 16 + 32 + 128 + 256, run[:seen]
  end

  def test_two_kept_variables_of_one_width_compare_as_their_numbers
    run = played do
      a = var :a, -1, width: :byte
      b = var :b, 127, width: :byte
      same = var :same, -1, width: :byte
      c = var :c, 0x1234, width: :half
      d = var :d, 0x1235, width: :half
      e = var :e, 0x2234, width: :half
      seen = var :seen, 0
      seen += 1 if a == same
      seen += 2 if a != b
      seen += 4 if a == b
      seen += 8 if c == d
      seen += 16 if c != e
      seen += 32 if c != d
    end

    assert_equal 1 + 2 + 16 + 32, run[:seen]
  end

  def test_turning_a_kept_variable_negative_keeps_its_width
    run = played do
      a = var :a, 5, width: :byte
      a = -a
      b = var :b, -300, width: :half
      negate! :b
      c = var :c, 256, width: :half
      c = -c
      d = var :d, -128, width: :byte
      d = -d
      e = var :e, -32_768, width: :half
      e = -e
    end

    assert_equal(-5, run[:a])
    assert_equal 300, run[:b]
    assert_equal(-256, run[:c], "the borrow crosses from the low byte to the high one")
    assert_equal(-128, run[:d], "128 has no place in a byte")
    assert_equal(-32_768, run[:e])
  end

  def test_a_product_kept_narrow_is_the_low_bits_of_the_whole_product
    run = played do
      a = var :a, 300, width: :half
      b = var :b, 200, width: :half
      c = var :c, -7, width: :byte
      d = var :d, 9, width: :byte
      over = var :over, 0, width: :half
      over = a * b
      under = var :under, 0, width: :half
      under = c * d
      byte = var :byte, 0, width: :byte
      byte = c * a
      masked = var :masked, 0, width: :half
      masked = (a & 0xff) * d
      written = var :written, 0, width: :half
      written = a * 1000
      none = var :none, 0, width: :half
      none = a * 0
    end

    assert_equal(-5536, run[:over], "60000 kept in a half")
    assert_equal(-63, run[:under])
    assert_equal(-52, run[:byte], "-2100 kept in a byte")
    assert_equal(396, run[:masked])
    assert_equal(-27_680, run[:written], "300000 kept in a half")
    assert_equal 0, run[:none]
  end

  def test_bit_sums_of_kept_variables_keep_their_width
    run = played do
      a = var :a, 0x1234, width: :half
      b = var :b, -256, width: :half
      x = var :x, 0, width: :half
      x = a ^ b
      y = var :y, 0, width: :half
      y = a & b
      z = var :z, 0, width: :half
      z = a | b
    end

    assert_equal(0x1234 ^ -256, run[:x])
    assert_equal(0x1234 & -256, run[:y])
    assert_equal(0x1234 | -256, run[:z])
  end

  def test_a_list_is_read_and_written_at_a_kept_variable_and_a_number
    run = played do
      slots = list :slots, capacity: 8, width: :byte
      8.times { |i| slots.push(i * 10) }
      first = var :first, 2, width: :half
      small = var :small, 5, width: :byte
      high = var :high, 0
      high = slots[first + 3]
      low = var :low, 0
      low = slots[small - 2]
      plain = var :plain, 0
      plain = slots[small]
      slots[first + 4] = 99
      slots[small - 5] = 77
      after = var :after, 0
      after = slots[6]
      start = var :start, 0
      start = slots[0]
    end

    assert_equal 50, run[:high]
    assert_equal 30, run[:low]
    assert_equal 50, run[:plain]
    assert_equal 99, run[:after]
    assert_equal 77, run[:start]
  end

  # Past either end the game stops as it would for any index, whatever the kept variable holds.
  def test_a_list_read_past_its_end_at_a_kept_variable_stops_the_game
    [[-3, 2], [30_000, 0], [32_767, 100], [6, 0], [-1, 0]].each do |at, added|
      error = assert_raises(StandardError) do
        played do
          slots = list :slots, capacity: 6, width: :byte
          6.times { |i| slots.push(i) }
          first = var :first, at, width: :half
          read = var :read, 0
          read = slots[first + added]
        end
      end

      assert_match(/list/i, error.message, "index #{at} + #{added}")
    end
  end

  # Anywhere a game gives a number, a kept variable can be it.
  def test_a_kept_variable_is_a_number_anywhere_one_goes
    run = played do
      clear_screen :black
      slots = list :slots, capacity: 4
      steps = table :steps, [5, 6, 7, 8]
      at = var :at, 2, width: :byte
      far = var :far, 40, width: :half
      slots.push(9)
      slots.push(10)
      slots.push(11)
      read = var :read, 0
      read = slots[at]
      looked = var :looked, 0
      looked = steps[at]
      total = var :total, 0
      repeat(at) { total += 1 }
      draw_rect_at far, at, at, at, :red
      draw_number :far, 10, 10, :white, digits: 2
    end

    assert_equal 11, run[:read]
    assert_equal 7, run[:looked]
    assert_equal 2, run[:total]
    assert_equal Color.resolve(:red), run.screen.pixel(40, 2)
  end

  # What a game can name a place by: a sprite stood where a kept variable says.
  def test_a_sprite_stands_where_a_kept_variable_says
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      hero = sprite :dot, at: [0, 0]
      x = var :x, 20, width: :byte
      game_loop do
        hero.x = x
        wait_vblank
      end
    end
    b.finalize_program
    run = game_player.run(b.program, frames: 4)

    assert_equal 20, run.sprites.first.x
  end

  def test_a_number_that_does_not_fit_is_refused
    error = assert_raises(ArgumentError) { played { var :x, 200, width: :byte } }
    assert_match(/-128 to 127/, error.message)

    error = assert_raises(ArgumentError) do
      played do
        x = var :x, 0, width: :byte
        x = 300
      end
    end
    assert_match(/:x/, error.message)
    assert_match(/-128 to 127/, error.message)
  end

  def test_a_save_record_cannot_keep_a_narrow_variable
    error = assert_raises(ArgumentError) do
      played do
        x = var :x, 0, width: :byte
        save_data(:file) { keep x }
      end
    end

    assert_match(/width: :byte/, error.message)
  end

  def test_a_fraction_cannot_be_narrow
    error = assert_raises(ArgumentError) { played { var :x, 1.5, width: :half } }

    assert_match(/fraction/, error.message)
  end

  def test_a_width_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { played { var :x, 0, width: :long } }

    assert_match(/:byte/, error.message)
    assert_match(/:half/, error.message)
  end

  def test_two_declarations_of_different_widths_are_refused
    error = assert_raises(ArgumentError) do
      played do
        var :x, 0, width: :byte
        var :x, 0, width: :half
      end
    end

    assert_match(/do not agree/, error.message)
  end

  def test_a_variable_kept_in_save_memory_cannot_be_narrow
    error = assert_raises(ArgumentError) do
      played do
        var :x, 0, width: :byte
        save_var :x, 0
      end
    end

    assert_match(/do not agree/, error.message)
  end
end
