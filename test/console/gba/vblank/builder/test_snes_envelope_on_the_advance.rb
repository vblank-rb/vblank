# frozen_string_literal: true

require "test_helper"
require "snes_envelope_tests"

# An instrument given the Super Nintendo sound chip's own envelope bytes, played as the Advance: the
# ordinary envelope nearest them. Here because a recording's shape is refused by the Color and the
# Genesis. The tests themselves are in test/snes_envelope_tests.rb.
class TestSNESEnvelopeOnTheAdvance < Minitest::Test
  include SNESEnvelopeTests
end
