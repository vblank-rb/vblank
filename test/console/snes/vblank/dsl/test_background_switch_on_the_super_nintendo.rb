# frozen_string_literal: true

require "test_helper"
require "background_switch_tests"

# A background switched off and on again, on the Super Nintendo, where it is a box with nothing in
# it, held by the layer's window: the tests every console that can leave a layer out plays
# (BackgroundSwitchTests in test/background_switch_tests.rb). The Advance's twin is
# test/console/gba/vblank/dsl/test_background_switch.rb.
class TestBackgroundSwitchOnTheSuperNintendo < Minitest::Test
  include BackgroundSwitchTests
end
