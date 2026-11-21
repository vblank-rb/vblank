# frozen_string_literal: true

require "test_helper"
require "song_instrument_tests"

# The tests of vblank/audio/test_song_instruments.rb that the Game Boy Color cannot play, played as the
# Advance; the rest are in that file, and the tests themselves in test/song_instrument_tests.rb.
class TestSongInstrumentsOnTheAdvance < Minitest::Test
  include SongInstrumentsTests
end
