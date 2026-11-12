# frozen_string_literal: true

require "test_helper"
require "pack_stand_in_size_tests"

# WHAT A PICTURE READ AS THE GAME STARTS COSTS THE GAME WRITTEN AS RUBY (PackStandInSizeTests in
# test/pack_stand_in_size_tests.rb): the game with its runtime, as a live game plays it.
class TestRubyPackStandInSize < Minitest::Test
  include PackStandInSizeTests

  private def written_bytes(program) = VBlank::IR::Backends::Ruby.new.live_source(program).bytesize
end
