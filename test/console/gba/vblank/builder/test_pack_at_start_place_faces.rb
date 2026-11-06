# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"

# A PLACE'S FACE DRAWN FROM THE DATA PACK as the game starts, on every run that plays as the Advance
# (PackAtStartPlaceTests in test/pack_at_start_tests.rb): the interpreter reading the pack, and the
# game as C, JavaScript and Ruby checked against it on every frame.
class TestPackAtStartPlaceFaces < Minitest::Test
  include PackAtStartPlaceTests
end
