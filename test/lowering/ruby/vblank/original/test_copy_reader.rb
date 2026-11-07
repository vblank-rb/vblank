# frozen_string_literal: true

require "test_helper"
require "copy_reader_tests"

# A port's unpacking routine built as Ruby, as a shell written as Ruby plays it (CopyReaderTests).
class TestCopyReaderAsRuby < Minitest::Test
  include CopyReaderTests
end
