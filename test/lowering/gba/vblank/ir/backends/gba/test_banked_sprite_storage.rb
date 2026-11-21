# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# A sprite of a pose of several banks (`image ..., banks:`) on the Advance's cartridge: each piece of
# the frame is a sprite entry of its own whose attribute 2 names that piece's bank (GBATEK, "LCD OBJ -
# OAM Attributes", bits 12-15), so the picture is stored half a byte a pixel like any sprite of one
# bank. Its pixels are held to the interpreter by test/console/gba/vblank/builder/
# test_pack_pose_banks_on_the_advance.rb; this is what it costs.
class TestBankedSpriteStorage < Minitest::Test
  include PackPoseBankColorGames

  # The frame of two banks is two 8x8 pieces: two tiles, half a byte a pixel.
  def test_a_pose_of_two_banks_is_stored_half_a_byte_a_pixel
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        sprite :mixed, at: [40, 40]
      end
      sprites = assemble_rom(program, name: "BANKED").built.video_memory.sprites

      assert_equal 1, sprites.small, "the sprite of two banks is stored the small way"
      assert_equal 0, sprites.big
      assert_equal 64, sprites.used, "two tiles of 8x8 pixels at half a byte each"
    end
  end

  # Poses taking turns, one the other turned round: the turned one keeps no tiles, and the two
  # others share the tile they hold alike, so three tiles at half a byte a pixel.
  def test_a_sprite_stepping_through_poses_of_several_banks_is_stored_half_a_byte_a_pixel
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 2, 3]
        image :plain, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 2, 3]
        sprite :walker, at: [40, 40], frames: [:mixed, :plain, mirror(:mixed)], rate: 1
      end
      sprites = assemble_rom(program, name: "WALKER").built.video_memory.sprites

      assert_equal 1, sprites.small
      assert_equal 0, sprites.big
      assert_operator sprites.used, :<=, 4 * 32, "at most four tiles at half a byte each"
    end
  end
end
