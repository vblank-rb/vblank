# frozen_string_literal: true

require "test_helper"
require "background_switch_tests"

# A BACKGROUND SWITCHED OFF AND ON AGAIN, on the PlayStation, whose build leaves a hidden background
# out of the drawing: the tests every console that can leave a layer out plays
# (BackgroundSwitchTests in test/background_switch_tests.rb). The Advance's twin is
# test/console/gba/vblank/dsl/test_background_switch.rb.
class TestBackgroundSwitchOnThePlayStation < Minitest::Test
  include BackgroundSwitchTests
end
