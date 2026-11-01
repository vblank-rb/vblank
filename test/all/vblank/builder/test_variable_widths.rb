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
