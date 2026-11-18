# frozen_string_literal: true

require "test_helper"
require "list_made_first_tests"

# A list reached before it is made stops the Color's game, as it stops the interpreter's
# (ListMadeFirstTests).
class TestGBCListMadeFirst < Minitest::Test
  include ListMadeFirstTests

  private def cartridge_run = VBlank::IR::Backends::GBC::HeadlessRun.new
end
