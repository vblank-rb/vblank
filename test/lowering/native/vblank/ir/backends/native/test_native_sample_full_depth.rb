# frozen_string_literal: true

require "test_helper"
require "full_depth_sound_tests"

# A 16-BIT RECORDING, played as C and checked against the interpreter on every frame
# (FullDepthSoundTests in test/full_depth_sound_tests.rb, which says why these are not in test/all/).
class TestNativeSampleFullDepth < Minitest::Test
  include FullDepthSoundTests
end
