# frozen_string_literal: true

require "test_helper"
require "dark_fade_tests"

# A dark picture fading to black, on a console that shows five bits of each channel.
class TestDarkFadeOnTheSuperNintendo < Minitest::Test
  include DarkFadeTests
end
