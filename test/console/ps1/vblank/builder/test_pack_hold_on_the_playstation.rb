# frozen_string_literal: true

require "test_helper"
require "pack_hold_tests"

# A recording's hold read from the data pack, built all-in-one, played as the PlayStation. The
# tests themselves are in test/pack_hold_tests.rb.
class TestPackHoldOnThePlayStation < Minitest::Test
  include PackHoldTests
end
