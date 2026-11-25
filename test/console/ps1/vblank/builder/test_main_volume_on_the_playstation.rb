# frozen_string_literal: true

require "test_helper"
require "main_volume_tests"

# The main volume, on the PlayStation: the tests every console with a main volume plays
# (MainVolumeTests in test/main_volume_tests.rb). What the sound chip's main volume registers hold
# is test/lowering/ps1/vblank/ir/backends/ps1/test_ps1_main_volume.rb's.
class TestMainVolumeOnThePlayStation < Minitest::Test
  include MainVolumeTests
end
