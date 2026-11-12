# frozen_string_literal: true

require "test_helper"
require "note_envelope_tests"

# A song's recorded notes with a shape, played as the PlayStation: each place falls away and gives its
# voice back as the interpreter's mix counts it. The tests themselves are in test/note_envelope_tests.rb.
class TestNoteEnvelopeOnThePlayStation < Minitest::Test
  include NoteEnvelopeVoiceTests
end
