# frozen_string_literal: true

require "test_helper"
require "pulled_tests"

# A gamepad's triggers part pulled, played as C and checked against the interpreter on every frame
# (PulledTests in test/pulled_tests.rb). The C runtime reads each pull above a player's buttons.
class TestNativePulled < Minitest::Test
  include PulledTests
end
