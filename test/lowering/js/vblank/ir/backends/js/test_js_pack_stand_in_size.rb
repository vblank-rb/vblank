# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# WHAT A PICTURE READ AS THE GAME STARTS COSTS THE GAME WRITTEN AS JAVASCRIPT (PackStandInSizeTests
# in test/pack_stand_in_size_tests.rb), which is what a web page holds of it.
class TestJSPackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::JS.new.lower(program).bytesize
end
