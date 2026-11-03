# frozen_string_literal: true

require "test_helper"
require "wanderers_tests"

# examples/wanderers.rb with four players, played as JavaScript and checked against the
# interpreter on every frame (WanderersTests in test/wanderers_tests.rb, which says why these are
# not in test/all/).
class TestJSWanderers < Minitest::Test
  include WanderersTests
end
