# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Super Nintendo: both cartridges in bsnes,
# whose samples the probe hands out as it does the Advance's.
class TestHeardAlikeOnTheSuperNintendo < Minitest::Test
  include HeardAlikeTests

  private def console = :snes

  # bsnes here mixes the sound chip's eight voices together and takes no setting to leave one out.
  private def voices_heard_alone? = false
end
