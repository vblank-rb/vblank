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

  # A computer game's original keeps its numbers in no console's layout. With nothing named they are
  # read low byte first, as DOS and Windows games keep them; a slot can name its byte order instead.
  def test_a_computer_originals_numbers_read_low_byte_first_unless_the_slot_names_its_byte_order
    words = [0x1234_5678, 0x0102_0304]
    assert_equal words, Slot.numbers(:sizes, at: 0, count: 2, width: :word, signed: false, layout: :pc).decode(words.pack("V*"))
    assert_equal words, Slot.numbers(:sizes, at: 0, count: 2, width: :word, signed: false, byte_order: :high_first)
                            .decode(words.pack("N*"))
    assert_equal [0x0102], Slot.numbers(:sizes, at: 0, count: 1, width: :half, signed: false, byte_order: :low_first)
                               .decode([0x0102].pack("v"))
  end

  # The same, as a game's data pack names its slots: halves of a computer original, low byte first
  # with nothing named, high byte first where the line says so.
  def test_a_computer_games_pack_reads_halves_low_byte_first_unless_the_line_names_its_byte_order
    slots = VBlank::DSL::PackSlots.new(platform: :pc)
    slots.numbers :plain, count: 1, width: :half, signed: false
    slots.numbers :turned, count: 1, width: :half, signed: false, byte_order: :high_first

    assert_equal [0x0102], slots.list.first.decode([0x0102].pack("v"))
    assert_equal [0x0102], slots.list.last.decode([0x0102].pack("n"))
  end

  def test_a_slot_naming_both_a_layout_and_a_byte_order_is_refused
    refused = assert_raises(ArgumentError) do
      Slot.numbers(:sizes, at: 0, count: 1, width: :half, signed: false, layout: :genesis, byte_order: :low_first)
    end

    assert_match "byte_order:", refused.message
  end

  def test_a_byte_order_that_is_not_low_or_high_first_is_refused
    refused = assert_raises(ArgumentError) { Slot.numbers(:sizes, at: 0, count: 1, width: :half, signed: false, byte_order: :big) }

    assert_match ":low_first", refused.message
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
