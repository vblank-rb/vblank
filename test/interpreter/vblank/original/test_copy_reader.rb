# frozen_string_literal: true

require "test_helper"
require "copy_reader_tests"

# A port's unpacking routine on the interpreter (CopyReaderTests), and what the build refuses as it
# plays the routine to make its pack (Builder::DataPacks#play_unpacking). The build plays it the
# same way on every run, so these are asked once, here.
class TestCopyReaderOnInterpreter < Minitest::Test
  include CopyReaderTests

  # What a pack of two tiles filled by +routine+ is refused with, as it is built.
  private def refusal_of_routine(error, &routine)
    Dir.mktmpdir do |folder|
      assert_raises(error) do
        Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.tiles :walls, count: 2
          slots.fill_from_copy(&routine)
        end
      end
    end
  end

  # Ten times the first speed is 100, past the 64 bytes of two tiles: a count worked out as the
  # routine runs cannot write into the next slot.
  def test_a_copy_too_long_for_its_slot_is_refused_at_build_time
    refused = refusal_of_routine(ArgumentError) do |copy, pack|
      copy.copy_bytes at: 0, count: copy.byte(SPEEDS_AT) * 10, into: pack[:walls]
    end

    assert_match ":walls", refused.message
    assert_match "bytes 0 to 63", refused.message
  end

  def test_a_byte_written_past_its_slot_is_refused_at_build_time
    refused = refusal_of_routine(ArgumentError) { |copy, pack| pack[:walls][copy.byte(SPEEDS_AT) * 10] = 1 }

    assert_match "byte 100 of slot :walls", refused.message
  end

  # A read past the copy's end, then a write past the slot that it led to: the read is the fault
  # the build names, since it came first.
  def test_a_read_past_the_end_of_the_copy_is_refused_naming_the_place
    refused = refusal_of_routine(VBlank::Original::WrongCopy) do |copy, pack|
      pack[:walls][0] = copy.byte(copy.byte(SPEEDS_AT) * 100)
      pack[:walls][copy.byte(SPEEDS_AT) * 10] = 1
    end

    assert_match "byte 1000", refused.message
    assert_match "0 to #{COPY_SIZE - 1}", refused.message
  end

  # The copy of an Advance original offers the Advance's formats, and no other unless the port
  # names it.
  def test_an_advance_copy_refuses_unpack_nemesis
    refused = refusal_of_routine(ArgumentError) { |copy, pack| copy.unpack_nemesis at: 0, into: pack[:walls] }

    assert_match "copy.unpack_nemesis", refused.message
    assert_match "Game Boy Advance", refused.message
    assert_match "lz77, rle", refused.message
    assert_match "nemesis is a format of Sega Genesis games", refused.message
    assert_match "formats:", refused.message
  end

  # Two formats of one routine name a working list alike, at two sizes. Formats share a list of one
  # name (Packing::BlockKit#list), which has one size, so the second size is refused naming both
  # formats and the list, whichever runs first: the bigger one's blocks would run off the end of the
  # smaller list, or the smaller one's would pass only in this order. Each keeps its first byte in
  # its list and writes it back.
  module KeptByteFormat
    def routine(block)
      kept = block.list(:kept, capacity: kept_capacity, width: :byte)
      kept[0] = block.byte(block.from)
      block.expect_size(1)
      block.write(kept[0])
    end
  end

  module FourKept
    extend VBlank::Original::Packing::Format
    extend KeptByteFormat
    unpacks :four_kept

    def self.kept_capacity = 4
  end

  module EightKept
    extend VBlank::Original::Packing::Format
    extend KeptByteFormat
    unpacks :eight_kept

    def self.kept_capacity = 8
  end

  private def build_refused_with(first, second)
    Dir.mktmpdir do |folder|
      assert_raises(ArgumentError) do
        Builder.new.data_pack(from: original(folder), version: "1", formats: [FourKept, EightKept]) do |slots|
          slots.numbers :kept, count: 2, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            copy.unpack(first, at: 0, into: pack[:kept])
            copy.unpack(second, at: 1, into: pack[:kept], start: 1)
          end
        end
      end
    end
  end

  def test_two_formats_naming_a_list_alike_at_two_sizes_are_refused
    [%i[four_kept eight_kept], %i[eight_kept four_kept]].each do |first, second|
      refused = build_refused_with(first, second)

      assert_match ":four_kept", refused.message
      assert_match ":eight_kept", refused.message
      assert_match ":kept", refused.message
      assert_match "capacity: 4", refused.message
      assert_match "capacity: 8", refused.message
    end
  end

  # A routine that never ends is stopped after as many frames as the copy and the pack have bytes,
  # not left to run for hours.
  def test_a_routine_that_never_ends_is_stopped
    Dir.mktmpdir do |folder|
      from = original(folder)
      refused = assert_raises(ArgumentError) do
        Builder.new.instance_eval do
          data_pack(from: from, version: "1") do |slots|
            slots.tiles :walls, count: 2
            slots.fill_from_copy do |copy, _pack|
              while copy.byte(0) >= 0
                wait_vblank
              end
            end
          end
        end
      end

      assert_match "did not get to its end", refused.message
    end
  end
end
