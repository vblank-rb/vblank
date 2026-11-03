# frozen_string_literal: true

require "test_helper"
require "background_box_tests"

# A BACKGROUND SHOWN ONLY INSIDE A BOX THE GAME MOVES AND SIZES, on the Advance: the tests every
# console that can hold a layer to a box plays (BackgroundBoxTests in test/background_box_tests.rb).
class TestBackgroundBox < Minitest::Test
  include BackgroundBoxTests
end
