# frozen_string_literal: true

require "test_helper"
require "called_routine_area_tests"

# A routine called from inside an area, held to it on the Super Nintendo (CalledRoutineAreaTests in
# test/called_routine_area_tests.rb). A routine on the Super FX chip inside an area is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_chip_columns.rb.
class TestCalledRoutineAreaOnTheSuperNintendo < Minitest::Test
  include CalledRoutineAreaTests
end
