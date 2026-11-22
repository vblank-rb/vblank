# frozen_string_literal: true

require "test_helper"
require "multitap_file_tests"

# A PlayStation program file played with a Multitap in its second port (MultitapFileTests).
class TestMultitapFileOnThePlayStation < Minitest::Test
  include MultitapFileTests

  private def cartridge_console = :ps1
end
