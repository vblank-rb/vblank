# frozen_string_literal: true

require "test_helper"
require "border_frame_tests"

# A Color game in the Advance's border, as the game as JavaScript shows it on its page.
class TestJSBorder < Minitest::Test
  include BorderFrameTests

  HeadlessRun = VBlank::IR::Backends::JS::HeadlessRun
end
