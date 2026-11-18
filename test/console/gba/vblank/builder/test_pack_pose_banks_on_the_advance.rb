# frozen_string_literal: true

require "test_helper"
require "differential"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# A POSE OF THE PIECES OF SEVERAL BANKS (`image ..., banks:`) on the Advance's cartridge, every pixel
# held to the interpreter: each piece in its own bank's colours, one sprite moving the whole frame.
# The games are test/all/vblank/builder/test_pack_pose_bank_colors.rb's made-up original.
class TestPackPoseBanksOnTheAdvance < Minitest::Test
  include Differential
  include PackPoseBankColorGames

  def test_a_pose_of_two_banks_is_drawn_as_the_interpreter_draws_it
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        mixed = sprite :mixed, at: [40, 40]
        mixed.move_to(96, 64)
      end

      assert_backends_agree(program, frames: 4)
    end
  end

  # A pose of two banks beside poses of one bank each, every one its own sprite.
  def test_poses_of_one_bank_beside_a_pose_of_two_are_drawn_as_the_interpreter_draws_them
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        test.declare_poses_for(self, pack)
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        sprite :first, at: [24, 24]
        sprite :second, at: [64, 24]
        sprite :mixed, at: [104, 24]
      end

      assert_backends_agree(program, frames: 4)
    end
  end
end
