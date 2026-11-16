# frozen_string_literal: true

require "test_helper"
require "main_volume_tests"

# THE MAIN VOLUME, on the Advance: the tests every console with a main volume plays (MainVolumeTests
# in test/main_volume_tests.rb). What SOUNDCNT holds is
# test/lowering/gba/vblank/ir/backends/gba/test_gba_main_volume.rb's.
class TestMainVolumeOnTheAdvance < Minitest::Test
  include MainVolumeTests
end
