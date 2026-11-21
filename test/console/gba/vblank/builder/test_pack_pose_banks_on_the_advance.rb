# frozen_string_literal: true

require "test_helper"
require "differential"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# A pose of the pieces of several banks (`image ..., banks:`) on the Advance's cartridge, every pixel
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

  # A frame whose pieces add their bank to the thing's, read by the game's reader: banks 4 and 2.
  def test_a_pose_whose_pieces_add_their_bank_to_the_things_is_drawn_as_the_interpreter_draws_it
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        test.declare_relative_bank_pose_for(self, pack)
        sprite :sword, at: [40, 40]
      end

      assert_backends_agree(program, frames: 4)
    end
  end

  # Each entry names its own bank, so where the piece of bank 3 sits half behind the piece of bank 1
  # the entry in front covers it, as the interpreter paints the earlier piece in front.
  def test_overlapping_pieces_of_two_banks_are_drawn_as_the_interpreter_draws_them
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :overlapping, tiles: pack[:video], frame: pack[:frames].frame(OVERLAPPING, layout: FRAME), origin: ORIGIN,
                            colors: pack[:palette], banks: [1, 3]
        sprite :overlapping, at: [40, 40]
      end

      assert_backends_agree(program, frames: 4)
    end
  end

  # Tiles whose first is see-through on its right half, so where the piece of bank 3 sits behind
  # the piece of bank 1 it shows through, and the entry of bank 1 must hold nothing there.
  HALF_SEE_THROUGH = Ractor.make_shareable([
    (0...64).map { |at| (at % 8) < 4 ? 1 + ((at / 8) % 3) : 0 },
    (0...64).map { |at| 1 + ((at % 8) % 3) }
  ])

  def test_a_piece_behind_a_see_through_part_of_another_banks_piece_is_drawn_as_the_interpreter_draws_it
    Dir.mktmpdir do |folder|
      program = game_of(folder, tiles: HALF_SEE_THROUGH) do |pack|
        image :overlapping, tiles: pack[:video], frame: pack[:frames].frame(OVERLAPPING, layout: FRAME), origin: ORIGIN,
                            colors: pack[:palette], banks: [1, 3]
        sprite :overlapping, at: [40, 40]
      end

      assert_backends_agree(program, frames: 4)
    end
  end

  # Banks of four colours on a sprite that turns: it is one entry of the whole picture, so it is
  # not cut into banks, and its places stay places in the one list of both banks. The copy is read
  # as the Color keeps its tiles, four colours each; what its bytes draw so is the interpreter's.
  def test_a_turning_sprite_of_small_banks_is_drawn_as_the_interpreter_draws_it
    Dir.mktmpdir do |folder|
      program = game_of(folder, tile_colors: 4, platform: :gbc) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:shifted], banks: [1, 3], size: [16, 16]
        spinner = sprite :mixed, at: [40, 40]
        spinner.turn 90
      end

      assert_backends_agree(program, frames: 4)
    end
  end

  # Poses of the same banks taking turns, one of them the other turned round, so the draw reads
  # each piece's bank beside its pose word as the pose changes.
  def test_a_sprite_stepping_through_poses_of_several_banks_is_drawn_as_the_interpreter_draws_it
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 2, 3]
        image :plain, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 2, 3]
        sprite :walker, at: [40, 40], frames: [:mixed, :plain, mirror(:mixed)], rate: 1
      end

      assert_backends_agree(program, frames: 3..8)
    end
  end

  # A pool's things each draw the pose of several banks.
  def test_a_pool_of_poses_of_several_banks_is_drawn_as_the_interpreter_draws_it
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        guards = pool :guard, x: 0, y: 0, capacity: 3, image: :mixed
        guards.spawn x: 40, y: 40
        guards.spawn x: 100, y: 70
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
