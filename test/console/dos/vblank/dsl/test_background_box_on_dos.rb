# frozen_string_literal: true

require "test_helper"
require "background_box_tests"

# A BACKGROUND SHOWN ONLY INSIDE A BOX THE GAME MOVES AND SIZES, on DOS: the tests every console that can hold
# a layer to a box plays (BackgroundBoxTests in test/background_box_tests.rb).
class TestBackgroundBoxOnDOS < Minitest::Test
  include BackgroundBoxTests
end
