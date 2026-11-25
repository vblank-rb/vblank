# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# What a picture read as the game starts costs the game written as C (PackStandInSizeTests in
# test/pack_stand_in_size_tests.rb): game.c and the files its big tables are embedded from.
class TestNativePackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::Native::Lowering.new(program, title: "VBlank").source_files.values.sum(&:bytesize)
  private def lowering_class = VBlank::IR::Backends::Native::Lowering
  private def headless_run = VBlank::IR::Backends::Native::HeadlessRun.new
end
