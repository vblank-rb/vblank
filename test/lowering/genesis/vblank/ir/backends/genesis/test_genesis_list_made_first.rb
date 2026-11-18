# frozen_string_literal: true

require "test_helper"
require "list_made_first_tests"

# A list reached before it is made stops the Genesis's game, as it stops the interpreter's
# (ListMadeFirstTests).
class TestGenesisListMadeFirst < Minitest::Test
  include ListMadeFirstTests

  private def cartridge_run = VBlank::IR::Backends::Genesis::HeadlessRun.new
end
