# frozen_string_literal: true

require "test_helper"
require "pack_tile_pose_at_start_tests"

# A POSE OF SPRITE TILES FROM A FRAME OF THE PACK, ITS PACK LEFT OUT, played on the interpreter
# (PackTilePoseAtStartTests in test/pack_tile_pose_at_start_tests.rb, which says why these are not
# in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackTilePoseAtStartInterpreter < Minitest::Test
  include PackTilePoseAtStartTests
end
