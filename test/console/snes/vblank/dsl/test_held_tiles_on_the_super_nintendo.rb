# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_held_tiles"

# A scene taking over beside a held box every screen shows, on the runs that play games as the
# Super Nintendo (HeldTilesSceneTests, in test/all/vblank/dsl/test_held_tiles.rb).
class TestHeldTilesOnTheSuperNintendo < Minitest::Test
  include HeldTilesSceneTests
end
