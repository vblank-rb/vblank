# frozen_string_literal: true

require "test_helper"
require "subtracting_layer_games"

# A light that takes away what is behind it (`subtract: true`) is refused on a PlayStation, in the words
# of its answers (Console::Questions#layers_question). Its graphics chip subtracts the other way round: what is behind less the layer (psx-spx,
# semi-transparency mode 2), and the layer is drawn after what is behind it.
# The Super Nintendo's test plays the same game.
class TestSubtractingLayerOnThePlayStation < Minitest::Test
  include SubtractingLayerGames

  def test_a_subtracting_light_is_refused_in_plain_words
    assert_subtracting_refused_on(:ps1, /cannot take what is behind away from the layer/)
  end
end
