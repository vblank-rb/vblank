# frozen_string_literal: true

require "test_helper"
require "full_depth_sound_tests"

# A 16-BIT RECORDING, played on the interpreter (FullDepthSoundTests in test/full_depth_sound_tests.rb,
# which says why these are not in test/all/). The game as C, as JavaScript and as Ruby play the same
# tests. What only the interpreter answers is here too: the console's own mix of the same game.
class TestSampleFullDepthInterpreter < Minitest::Test
  include FullDepthSoundTests

  # The console's mix of a 16-bit recording is the mix of its high bytes, the bytes it held before
  # a game could give sixteen bits: 300 is 1.
  def test_the_consoles_mix_of_a_16_bit_recording_is_its_high_byte
    full = Reference.new.run(looping_game(hum: { pcm: [QUIET] * 64, bits: 16, rate: 8192 }), frames: 4)
    high = Reference.new.run(looping_game(hum: { pcm: [QUIET >> 8] * 64, rate: 8192 }), frames: 4)

    assert_equal high.mixed_sound, full.mixed_sound
    assert_equal [1], full.mixed_sound.flatten.uniq
  end
end
