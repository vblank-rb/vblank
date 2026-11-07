# frozen_string_literal: true

require "test_helper"
require "packing_genesis_tests"

# The Sega Genesis's formats in an unpacking routine built as C (PackingGenesisTests).
class TestPackingGenesisAsC < Minitest::Test
  include PackingGenesisTests
end
