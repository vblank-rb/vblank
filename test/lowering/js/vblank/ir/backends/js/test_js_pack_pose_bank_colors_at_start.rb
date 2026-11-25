# frozen_string_literal: true

require "test_helper"
require "pack_pose_bank_colors_at_start_tests"

# A pose in the bank its frame names, its pack left out, played as JavaScript by node and checked
# against the interpreter on every frame (PackPoseBankColorsAtStartTests in
# test/pack_pose_bank_colors_at_start_tests.rb, which says why these are not in test/all/).
class TestJSPackPoseBankColorsAtStart < Minitest::Test
  include PackPoseBankColorsAtStartTests
end
