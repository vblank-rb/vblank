# frozen_string_literal: true

require "test_helper"

# One slot of a data pack (Original::Slot): its size comes from its shape and count, and its bytes
# read in the layout the original keeps them in (today the Game Boy Advance's).
class TestOriginalSlot < Minitest::Test
  Slot = VBlank::Original::Slot

  def test_each_shape_says_how_many_bytes_the_slot_holds
    assert_equal 32, Slot.colors(:palette, at: 0, count: 16).byte_size
    assert_equal 64, Slot.tiles(:walls, at: 0, count: 2).byte_size
    assert_equal 12, Slot.numbers(:speeds, at: 0, count: 3, width: :word, signed: false).byte_size
  end

  def test_colours_read_two_bytes_each_low_byte_first
    assert_equal [0x001F, 0x7FFF], Slot.colors(:palette, at: 0, count: 2).decode([0x001F, 0x7FFF].pack("v*"))
  end

  # Two pixels a byte, the left one in the low half.
  def test_a_tile_reads_as_its_sixty_four_places
    assert_equal [[1, 2] * 32], Slot.tiles(:walls, at: 0, count: 1).decode(([0x21] * 32).pack("C*"))
  end

  def test_numbers_read_below_zero_only_in_a_signed_slot
    assert_equal [1, 65_535, 2], Slot.numbers(:speeds, at: 0, count: 3, width: :half, signed: false).decode([1, 65_535, 2].pack("v*"))
    assert_equal [-1, 5], Slot.numbers(:dips, at: 0, count: 2, width: :byte, signed: true).decode([255, 5].pack("C*"))
  end

  def test_a_slot_of_numbers_must_say_whether_they_are_signed
    refused = assert_raises(ArgumentError) { Slot.numbers(:speeds, at: 0, count: 1, width: :byte, signed: nil) }

    assert_match "signed: true or signed: false", refused.message
  end

  def test_a_slot_past_the_end_of_the_copy_is_refused_naming_the_slot
    refused = assert_raises(VBlank::Original::WrongCopy) do
      Slot.numbers(:late, at: 60, count: 8, width: :byte, signed: false).cut_from("\0".b * 64)
    end

    assert_match ":late", refused.message
  end
end
