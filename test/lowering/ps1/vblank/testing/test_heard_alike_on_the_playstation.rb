# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the PlayStation: both programs in Beetle PSX,
# whose samples the probe hands out as it does every other console's. Beetle mixes the sound chip's
# 24 voices into one output and has no setting to leave one out, so no voice is heard alone here.
class TestHeardAlikeOnThePlayStation < Minitest::Test
  include HeardAlikeTests

  private def console = :ps1

  private def voices_heard_alone? = false
end
