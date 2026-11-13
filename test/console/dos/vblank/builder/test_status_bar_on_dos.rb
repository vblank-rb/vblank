# frozen_string_literal: true

require "test_helper"
require "status_bar_games"

# What a status bar does on DOS, which the Color refuses (Checks::StatusBarCannotShare): a sprite stacked
# behind the field, which DOS's build draws into the view a level of the stack at a time, with the bar drawn
# first and the field kept above the bar's top.
class TestStatusBarOnDOS < Minitest::Test
  include SpriteBehindFieldOverBarTests
end
