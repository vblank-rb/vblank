# frozen_string_literal: true

require "test_helper"
require "pack_hold_tests"

# A recording's hold read from the data pack, built all-in-one, played as the Super Nintendo. The
# tests themselves are in test/pack_hold_tests.rb.
class TestPackHoldOnTheSuperNintendo < Minitest::Test
  include PackHoldTests
end
