# frozen_string_literal: true

require "test_helper"

# A list declared `width: :unsigned_half` is kept in two bytes a slot on the Advance and read back
# with no sign: 65535 and 40000 come back as themselves, 65536 as 0, and the answers are the
# interpreter's.
class TestUnsignedHalfList < Minitest::Test
  private def rom
    VBlank.build("UHALF", console: :gba, out: nil, err: nil) do
      screen :bitmap
      places = list :places, capacity: 5, width: :unsigned_half, full_of: 0
      read = list :read, capacity: 6, width: :word, full_of: 0
      done = 0
      game_loop do
        if done.zero?
          [65_535, 40_000, 65_536, 32_768, 7].each_with_index { |number, at| places[at] = number }
          5.times { |at| read[at] = places[at] }
          read[5] = -1
          done = 1
        end
      end
    end
  end

  def test_the_list_is_two_bytes_a_slot
    place = rom.built.lists.fetch(:places)

    assert_equal 2, place.bytes
    assert_equal 4, rom.built.lists.fetch(:read).bytes
  end

  def test_the_numbers_read_back_with_no_sign_as_the_interpreter_reads_them
    built = rom
    got = VBlank::Diagnostics::Verifier.new(built, frames: 6, vars: built.var_addresses)
    want = VBlank::IR::Backends::Reference.new.run(built.source_program, frames: 6)

    assert_equal [65_535, 40_000, 0, 32_768, 7, -1], want.list(:read)
    assert_equal want.list(:read), got.list(:read), "read through the two-byte slots"
    assert_equal want.list(:places), got.list(:places)
  end
end
