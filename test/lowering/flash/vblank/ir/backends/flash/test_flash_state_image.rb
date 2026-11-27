# frozen_string_literal: true

require "test_helper"
require "state_image_tests"

# The state image of the game built as a Flash movie (StateImageTests in test/state_image_tests.rb), read across from and
# into the game built as Ruby and as JavaScript. The native runtime needs zig, which is not always here, and it is held
# to the other two by its own test.
class TestFlashStateImage < Minitest::Test
  include StateImageTests

  private def state_run = VBlank::IR::Backends::Flash::HeadlessRun.new
  private def other_runs = [VBlank::IR::Backends::Ruby::HeadlessRun.new, VBlank::IR::Backends::JS::HeadlessRun.new]
end
