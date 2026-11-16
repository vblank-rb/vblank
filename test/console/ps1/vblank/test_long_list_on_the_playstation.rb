# frozen_string_literal: true

require "test_helper"
require "long_list_tests"

# A list of more than 65,535 slots on the PlayStation, whose 2 megabytes hold one of words
# (LongListTests in test/long_list_tests.rb).
class TestLongListOnThePlayStation < Minitest::Test
  include LongListTests

  LIST_WIDTH = :word
end
