# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# WHAT A PICTURE READ AS THE GAME STARTS COSTS THE GAME WRITTEN AS C (PackStandInSizeTests in
# test/pack_stand_in_size_tests.rb): game.c and the files its big tables are embedded from.
class TestNativePackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::Native::Lowering.new(program, title: "VBlank").source_files.values.sum(&:bytesize)
end
