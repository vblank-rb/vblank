# frozen_string_literal: true

require "test_helper"
require "subtracting_layer_games"

# A light that takes away what is behind it (`subtract: true`) is refused on a Game Boy Color, in the words
# of its answers (Console::Questions#layers_question). It cannot show one layer through another at all.
# The Super Nintendo's test plays the same game.
class TestSubtractingLayerOnTheColor < Minitest::Test
  include SubtractingLayerGames

  def test_a_subtracting_light_is_refused_in_plain_words
    assert_subtracting_refused_on(:gbc, /cannot show one layer through another/)
  end
end
