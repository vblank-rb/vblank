# frozen_string_literal: true

require "test_helper"
require "main_volume_tests"

# THE MAIN VOLUME, on the Color: the tests every console with a main volume plays (MainVolumeTests
# in test/main_volume_tests.rb). What NR50 holds is
# test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_main_volume.rb's.
class TestMainVolumeOnTheColor < Minitest::Test
  include MainVolumeTests
end
