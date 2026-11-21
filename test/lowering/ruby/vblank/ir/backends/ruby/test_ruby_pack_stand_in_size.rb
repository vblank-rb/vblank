# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# What a picture read as the game starts costs the game written as Ruby (PackStandInSizeTests in
# test/pack_stand_in_size_tests.rb): the game with its runtime, as a live game plays it.
class TestRubyPackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::Ruby.new.live_source(program).bytesize
  private def lowering_class = VBlank::IR::Backends::Ruby::Lowering
  private def headless_run = VBlank::IR::Backends::Ruby::HeadlessRun.new
end
