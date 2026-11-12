# frozen_string_literal: true

require "test_helper"
require "mixed_sound"
require "pack_hold_tests"

# A recording's hold read from the data pack, built all-in-one, played as the Advance. The tests
# themselves are in test/pack_hold_tests.rb; here, the Advance's mixer makes the same bytes for a
# recording the pack says does not loop.
class TestPackHoldOnTheAdvance < Minitest::Test
  include MixedSound
  include PackHoldTests

  # A held from the first frame on, so the cartridge sees it press once its frames of setting
  # itself up are over; the sound is compared from where it starts.
  def test_a_hold_of_every_bit_set_from_the_pack_is_mixed_into_the_same_bytes
    Dir.mktmpdir do |folder|
      presses = (0..30).to_h { |frame| [frame, [:a]] }
      assert_mixes_agree(hold_game(folder, from: :no_hold), frames: 20, presses: presses, at_least: 4)
    end
  end
end
