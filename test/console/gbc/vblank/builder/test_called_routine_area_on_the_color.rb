# frozen_string_literal: true

require "test_helper"
require "called_routine_area_tests"

# A routine called from inside an area, held to it on the Color (CalledRoutineAreaTests in
# test/called_routine_area_tests.rb).
class TestCalledRoutineAreaOnTheColor < Minitest::Test
  include CalledRoutineAreaTests
end
