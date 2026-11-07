# frozen_string_literal: true

require "test_helper"
require "packing_genesis_tests"

# The Sega Genesis's formats in an unpacking routine on the interpreter (PackingGenesisTests), and
# the refusals the build finds as it plays the routine there: a block that would write past its
# slot.
class TestPackingGenesisOnInterpreter < Minitest::Test
  include PackingGenesisTests

  # Three tiles are 96 bytes, and the slot holds two.
  def test_a_nemesis_block_too_big_for_its_slot_is_refused
    refused = assert_raises(ArgumentError) do
      genesis_unpacking(GenesisPackingAnswers.nemesis_block(GENESIS_TILES, xor: false) + FILLER) do |slots|
        slots.tiles :art, count: 2, layout: :genesis
        slots.fill_from_copy { |bytes, pack| bytes.unpack_nemesis at: 0, into: pack[:art] }
      end
    end

    assert_match ":art", refused.message
    assert_match "bytes 0 to 63", refused.message
  end

  # Four cells fit; the fifth would start at byte 8.
  def test_an_enigma_map_written_past_its_slot_is_refused
    refused = assert_raises(ArgumentError) do
      genesis_unpacking(FILLER + MAP + FILLER) { |slots| map_slots(slots, count: 4) }
    end

    assert_match "byte 8 of slot :map", refused.message
  end
end
