# frozen_string_literal: true

require "test_helper"
require "state_image_tests"

# The state image of the game built as JavaScript (StateImageTests in test/state_image_tests.rb),
# read across from and into the game built as Ruby.
class TestJSStateImage < Minitest::Test
  include StateImageTests

  private def state_run = VBlank::IR::Backends::JS::HeadlessRun.new
  private def other_runs = [VBlank::IR::Backends::Ruby::HeadlessRun.new]
end
