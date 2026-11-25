# frozen_string_literal: true

require "test_helper"
require "pulled_tests"

# A gamepad's triggers part pulled, played as JavaScript and checked against the interpreter on
# every frame (PulledTests in test/pulled_tests.rb).
class TestJSPulled < Minitest::Test
  include PulledTests
end
