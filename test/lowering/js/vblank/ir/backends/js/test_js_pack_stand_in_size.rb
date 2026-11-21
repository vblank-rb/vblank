# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# What a picture read as the game starts costs the game written as JavaScript (PackStandInSizeTests
# in test/pack_stand_in_size_tests.rb), which is what a web page holds of it.
class TestJSPackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::JS.new.lower(program).bytesize
  private def lowering_class = VBlank::IR::Backends::JS::Lowering
  private def headless_run = VBlank::IR::Backends::JS::HeadlessRun.new
end
