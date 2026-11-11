# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Sega Genesis: both cartridges in Genesis Plus GX.
class TestHeardAlikeOnTheGenesis < Minitest::Test
  include HeardAlikeTests

  private def console = :genesis

  # Genesis Plus GX's output is heard settling for a few frames after power-on, on any cartridge.
  private def alike_settings = STRICT.merge(lead_ins: [past_the_power_on_click, past_the_power_on_click])
end
