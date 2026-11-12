# frozen_string_literal: true

require "test_helper"
require "status_bar_games"

# What a status bar does on the PlayStation, which the Color refuses (Checks::StatusBarCannotShare): a
# sprite stacked behind the field, which the PlayStation's build draws a level of the stack at a time
# (Runtime::Tiles' rt_tiles_draw), with the bar drawn first and the field kept above the bar's top.
class TestStatusBarOnThePlayStation < Minitest::Test
  include SpriteBehindFieldOverBarTests
end
