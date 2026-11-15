# frozen_string_literal: true

require "test_helper"
require "layer_over_sprites_tests"

# A see-through background over sprites, on every run that plays games as the Advance. The games
# and the tests are LayerOverSpritesTests', which the PlayStation's runs play too.
class TestLayerOverSpritesOnTheAdvance < Minitest::Test
  include LayerOverSpritesTests
end
