# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "list_reading_tests"

class TestReadingListsOnTheColor < Minitest::Test
  include ListReadingTests

  private def console = :gbc
end
