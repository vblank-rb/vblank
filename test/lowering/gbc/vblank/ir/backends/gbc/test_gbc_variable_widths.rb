# frozen_string_literal: true

require "test_helper"

# WHAT A KEPT WIDTH SAVES on the Color, whose processor works a byte at a time: the same game with
# and without `width:`, compared by the size of what it was made into.
class TestGBCVariableWidths < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def code_size(**kept)
    rom = VBlank.build("WIDTHS", console: :gbc, out: StringIO.new, err: StringIO.new) do
      flag = var :flag, 0, **kept
      speed = var :speed, 3, **kept
      turns = var :turns, 0, **kept
      game_loop do
        turns += 1 if flag == 2
        speed = speed + turns
        flag = 1 if speed > 40
        flag = 0
        wait_vblank
      end
    end
    rom.bytes.each_byte.count { |byte| !byte.zero? && byte != 0xFF } # what is not the cartridge's padding
  end

  # The machine code of a routine holding +body+, with the variables a test of it uses.
  private def listing_of(&body)
    out = StringIO.new
    VBlank.build("WIDTHS", console: :gbc, out: out, err: StringIO.new) do
      func(:sums) { instance_eval(&body) }
      dump_func :sums
      game_loop do
        call :sums
        wait_vblank
      end
    end
    out.string
  end

  def test_two_bytes_compare_with_no_four_byte_helper
    listed = listing_of do
      a = var :a, 1, width: :byte
      b = var :b, 2, width: :byte
      c = var :c, 3, width: :half
      d = var :d, 4, width: :half
      n = var :n, 0
      n = 1 if a != b
      n = 2 if c == d
    end

    refute_match(/rt_cmp32/, listed)
  end

  def test_turning_a_kept_variable_negative_calls_no_four_byte_helper
    listed = listing_of do
      a = var :a, 1, width: :half
      a = -a
      b = var :b, 1, width: :byte
      negate! :b
    end

    refute_match(/rt_neg32/, listed)
  end

  def test_a_product_kept_in_two_bytes_works_in_two_bytes
    listed = listing_of do
      a = var :a, 1, width: :half
      b = var :b, 2, width: :half
      a = (a & 0xff) * b
    end

    refute_match(/rt_mul32/, listed)
  end

  def test_a_list_at_a_kept_variable_and_a_number_adds_and_checks_in_two_bytes
    listed = listing_of do
      slots = list :slots, capacity: 8, width: :byte
      first = var :first, 1, width: :half
      n = var :n, 0
      n = slots[first + 3]
      slots[first + 1] = 2
    end
    fast_path = listed.split("list_index_out_of_range", 2).first

    refute_match(/ld c,|ld b,/, fast_path, "nothing above the two bytes is worked out")
  end

  def test_a_byte_is_read_written_and_compared_in_far_less_code
    assert_operator code_size(width: :byte), :<, code_size - 40
  end

  def test_a_game_that_says_nothing_keeps_its_bytes
    assert_equal code_size, code_size(width: :word)
  end
end
