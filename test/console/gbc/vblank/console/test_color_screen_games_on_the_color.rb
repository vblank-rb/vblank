# frozen_string_literal: true

require "test_helper"
require "color_screen_tests"

# A game laid out for the Game Boy Color, played on the Color: the tests the two consoles share
# (ColorScreenTests in test/color_screen_tests.rb). The Advance's twin, in its border, is
# test/console/gba/vblank/console/test_color_screen_games.rb.
class TestColorScreenGamesOnTheColor < Minitest::Test
  include ColorScreenTests
end
