# frozen_string_literal: true

require "test_helper"
require "wanderers_tests"

# examples/wanderers.rb with four players, played on the interpreter (WanderersTests in
# test/wanderers_tests.rb, which says why these are not in test/all/). The game as C, as
# JavaScript and as Ruby play the same tests.
class TestWanderersInterpreter < Minitest::Test
  include WanderersTests
end
