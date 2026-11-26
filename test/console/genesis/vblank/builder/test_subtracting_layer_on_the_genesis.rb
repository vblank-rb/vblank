# frozen_string_literal: true

require "test_helper"
require "subtracting_layer_games"

# A light that takes away what is behind it (`subtract: true`) is refused on a Genesis, in the words
# of its answers (Console::Questions#layers_question). It mixes no layer into another: its shadow and highlight darken or brighten by one fixed step.
# The Super Nintendo's test plays the same game.
class TestSubtractingLayerOnTheGenesis < Minitest::Test
  include SubtractingLayerGames

  def test_a_subtracting_light_is_refused_in_plain_words
    assert_subtracting_refused_on(:genesis, /cannot take one layer away from another/)
  end
end
