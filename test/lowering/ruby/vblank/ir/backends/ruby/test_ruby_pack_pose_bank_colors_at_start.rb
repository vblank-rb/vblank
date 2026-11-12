# frozen_string_literal: true

require "test_helper"
require "pack_pose_bank_colors_at_start_tests"

# A POSE IN THE BANK ITS FRAME NAMES, ITS PACK LEFT OUT, played as Ruby and checked against the
# interpreter on every frame (PackPoseBankColorsAtStartTests in
# test/pack_pose_bank_colors_at_start_tests.rb, which says why these are not in test/all/).
class TestRubyPackPoseBankColorsAtStart < Minitest::Test
  include PackPoseBankColorsAtStartTests
end
