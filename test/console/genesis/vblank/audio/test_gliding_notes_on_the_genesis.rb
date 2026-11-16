# frozen_string_literal: true

require "test_helper"
require "gliding_note_tests"

# A recorded note that glides, played as the Genesis; the tests are in test/gliding_note_tests.rb. The
# Genesis plays a recording flat out, so the test of a glide through a fade is not among them.
class TestGlidingNotesOnTheGenesis < Minitest::Test
  include GlidingNoteTests
end
