# frozen_string_literal: true

require "test_helper"
require "main_volume_tests"

# The main volume, on the Super Nintendo: the tests every console with a main volume plays
# (MainVolumeTests in test/main_volume_tests.rb). What the sound chip's registers hold is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_main_volume.rb's.
class TestMainVolumeOnTheSuperNintendo < Minitest::Test
  include MainVolumeTests
end
