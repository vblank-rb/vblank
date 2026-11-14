# frozen_string_literal: true

require "test_helper"
require "border_frame_tests"

# A Color game in the Advance's border, as the game as C shows it in its window.
class TestNativeBorder < Minitest::Test
  include BorderFrameTests

  HeadlessRun = VBlank::IR::Backends::Native::HeadlessRun
end
