# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_fade"

# How far a fade goes at each step, on a console that fades by walking its colours.
class TestFadeOnTheColor < Minitest::Test
  include FadeShareTests
end
