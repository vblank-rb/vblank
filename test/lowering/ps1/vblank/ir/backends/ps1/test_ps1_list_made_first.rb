# frozen_string_literal: true

require "test_helper"
require "list_made_first_tests"

# A list reached before it is made stops the PlayStation's game, as it stops the interpreter's
# (ListMadeFirstTests).
class TestPS1ListMadeFirst < Minitest::Test
  include ListMadeFirstTests

  private def cartridge_run = VBlank::IR::Backends::PS1::HeadlessRun.new
end
