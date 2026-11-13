# frozen_string_literal: true

require "test_helper"
require "background_above_row_tests"

# A background held above a row of the screen, on DOS, whose processor builds the view and draws each
# background only in the rows it is seen in: the tests every console that can hold one plays
# (BackgroundAboveRowTests).
class TestBackgroundAboveRowOnDOS < Minitest::Test
  include BackgroundAboveRowTests

  private def built_for = :dos
end
