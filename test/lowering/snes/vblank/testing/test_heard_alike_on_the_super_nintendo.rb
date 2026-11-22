# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Super Nintendo: both cartridges in bsnes,
# whose samples the probe hands out as it does the Advance's, and whose eight voices it can hear one
# at a time (test_heard_voices_on_the_super_nintendo.rb).
class TestHeardAlikeOnTheSuperNintendo < Minitest::Test
  include HeardAlikeTests

  private def console = :snes

  # A song's parts take the sound chip's voices in order from the first.
  private def part_voices = %i[voice0 voice1]

  # The build puts a recorded note of an effect in whichever place is free or ranks lowest.
  private def sound_effects_followed? = true
end
