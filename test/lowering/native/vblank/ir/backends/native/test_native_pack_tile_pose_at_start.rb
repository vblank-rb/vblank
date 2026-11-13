# frozen_string_literal: true

require "test_helper"
require "pack_tile_pose_at_start_tests"

# A POSE OF SPRITE TILES FROM A FRAME OF THE PACK, ITS PACK LEFT OUT, played as C and checked
# against the interpreter on every frame (PackTilePoseAtStartTests in
# test/pack_tile_pose_at_start_tests.rb, which says why these are not in test/all/). The C runtime
# writes the frame's pieces over the pose's stand-ins before the game's first statement.
class TestNativePackTilePoseAtStart < Minitest::Test
  include PackTilePoseAtStartTests
end
