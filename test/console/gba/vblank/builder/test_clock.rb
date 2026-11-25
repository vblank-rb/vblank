# frozen_string_literal: true

require "test_helper"
require "clock_tests"

# The date and time, read by the game, on the Advance: the tests every console with a clock plays
# (ClockTests in test/clock_tests.rb). The Color's twin is
# test/console/gbc/vblank/builder/test_clock_on_the_color.rb.
class TestClock < Minitest::Test
  include ClockTests
end
