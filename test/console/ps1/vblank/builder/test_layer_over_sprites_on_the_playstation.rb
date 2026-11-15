# frozen_string_literal: true

require "test_helper"
require "layer_over_sprites_tests"

# A see-through background over sprites, on every run that plays games as the PlayStation: its
# graphics chip mixes the cloud with the sprites drawn behind it. The games and the tests are
# LayerOverSpritesTests', which the Advance's runs play too.
class TestLayerOverSpritesOnThePlayStation < Minitest::Test
  include LayerOverSpritesTests
end
