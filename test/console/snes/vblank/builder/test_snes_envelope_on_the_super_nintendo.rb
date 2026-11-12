# frozen_string_literal: true

require "test_helper"
require "snes_envelope_tests"

# An instrument given the Super Nintendo sound chip's own envelope bytes, played as the Super
# Nintendo: its places keep the count of the ordinary envelope nearest them, as the interpreter
# does, while the chip shapes what is heard. The tests themselves are in test/snes_envelope_tests.rb.
class TestSNESEnvelopeOnTheSuperNintendo < Minitest::Test
  include SNESEnvelopeTests
end
