# frozen_string_literal: true

require "test_helper"
require "subtracting_layer_games"

# A light that takes away what is behind it (`subtract: true`) is refused on an Advance, in the words
# of its answers (Console::Questions#layers_question). Its display adds a layer to what is behind it, and darkens or brightens the whole picture, but
# cannot take one away from the other.
# The Super Nintendo's test plays the same game.
class TestSubtractingLayerOnTheAdvance < Minitest::Test
  include SubtractingLayerGames

  def test_a_subtracting_light_is_refused_in_plain_words
    assert_subtracting_refused_on(:gba, /cannot take what is behind a layer\s+away/)
  end
end
