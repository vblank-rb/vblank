# frozen_string_literal: true

require "test_helper"
require "long_list_tests"

# A list of more than 65,535 slots on the Advance, whose 256K of roomy memory holds one of bytes
# (LongListTests in test/long_list_tests.rb).
class TestLongListOnTheAdvance < Minitest::Test
  include LongListTests

  LIST_WIDTH = :byte
end
