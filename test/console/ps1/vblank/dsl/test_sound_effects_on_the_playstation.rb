# frozen_string_literal: true

require "test_helper"
require "sound_effect_recording_tests"

# Sound effects whose parts play a recording, played as the PlayStation: each recorded note in a place
# of the effect's own, shared with the song and the game's sounds by rank. The tests themselves are in
# test/sound_effect_recording_tests.rb.
class TestSoundEffectsOnThePlayStation < Minitest::Test
  include SoundEffectRecordingTests
end
