# frozen_string_literal: true

require "test_helper"
require "background_above_row_tests"

# A background held above a row of the screen, on the Super Nintendo: the tests every console that can hold
# one plays (BackgroundAboveRowTests).
class TestBackgroundAboveRow < Minitest::Test
  include BackgroundAboveRowTests

  private def built_for = :snes
end
