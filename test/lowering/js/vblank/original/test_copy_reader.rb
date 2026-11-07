# frozen_string_literal: true

require "test_helper"
require "copy_reader_tests"

# A port's unpacking routine built as JavaScript, as a shell's web page plays it (CopyReaderTests).
class TestCopyReaderAsJS < Minitest::Test
  include CopyReaderTests
end
