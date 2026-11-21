# frozen_string_literal: true

require "test_helper"
require "color_screen_tests"

# A game laid out for the Game Boy Color, played as the Advance in its border: the tests the two
# consoles share (ColorScreenTests in test/color_screen_tests.rb). The Color's twin is
# test/console/gbc/vblank/console/test_color_screen_games_on_the_color.rb.
class TestColorScreenGames < Minitest::Test
  include ColorScreenTests
end
