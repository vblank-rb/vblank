# frozen_string_literal: true

require "test_helper"
require "status_bar_games"

# What a status bar does on the Super Nintendo, which the Color refuses (Checks::StatusBarCannotShare): a
# sprite stacked behind the field, which the Super Nintendo's build shows with the bar on its third layer,
# behind every sprite, and the field kept above the bar's top (Lowering::Picture.third_layer?).
class TestStatusBarOnTheSuperNintendo < Minitest::Test
  include SpriteBehindFieldOverBarTests
end
