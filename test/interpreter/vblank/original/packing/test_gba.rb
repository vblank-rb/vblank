# frozen_string_literal: true

require "test_helper"
require "packing_gba_tests"

# The Game Boy Advance BIOS's formats in an unpacking routine on the interpreter (PackingGBATests),
# and the refusal of a block of another scheme, which the build finds as it plays the routine there.
class TestPackingGBAOnInterpreter < Minitest::Test
  include PackingGBATests

  def test_a_block_that_is_not_packed_the_way_the_routine_says_is_refused_at_build_time
    refused = Dir.mktmpdir do |folder|
      assert_raises(VBlank::Original::WrongCopy) do
        Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.tiles :walls, count: 2
          slots.fill_from_copy { |copy, pack| copy.unpack_lz77 at: RLE_AT, into: pack[:walls] }
        end
      end
    end

    assert_match "LZ77", refused.message
    assert_match RLE_AT.to_s, refused.message
  end

  # A voice of the console's own has no recording to read.
  def test_a_recording_read_from_a_voice_that_plays_none_is_refused_at_build_time
    square = M4AAnswers::GROUP_AT + 12
    refused = Dir.mktmpdir do |folder|
      assert_raises(VBlank::Original::WrongCopy) do
        Builder.new.data_pack(from: copy_of(folder, M4AAnswers::COPY), version: "1") do |slots|
          slots.samples :wave, count: 40
          slots.fill_from_copy { |copy, pack| copy.unpack_m4a_recording at: square, into: pack[:wave] }
        end
      end
    end

    assert_match "MusicPlayer2000 recording", refused.message
    assert_match square.to_s, refused.message
  end
end
