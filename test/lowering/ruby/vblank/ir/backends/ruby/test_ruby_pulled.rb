# frozen_string_literal: true

require "test_helper"
require "pulled_tests"

# A gamepad's triggers part pulled, played as Ruby and checked against the interpreter on every
# frame (PulledTests in test/pulled_tests.rb).
class TestRubyPulled < Minitest::Test
  include PulledTests
end
