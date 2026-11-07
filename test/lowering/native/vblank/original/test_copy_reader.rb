# frozen_string_literal: true

require "test_helper"
require "copy_reader_tests"

# A port's unpacking routine built as C, as a shell's desktop program plays it (CopyReaderTests).
class TestCopyReaderAsC < Minitest::Test
  include CopyReaderTests
end
