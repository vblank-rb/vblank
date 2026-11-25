# frozen_string_literal: true

require "test_helper"
require "multitap_file_tests"

# A Genesis cartridge file played with a Team Player in its second port, and compared with itself
# on a tape (MultitapFileComparisonTests).
class TestMultitapFileOnTheGenesis < Minitest::Test
  include MultitapFileComparisonTests

  private def cartridge_console = :genesis
end
