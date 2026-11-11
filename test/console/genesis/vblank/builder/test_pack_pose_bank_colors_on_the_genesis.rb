# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# ONE SPRITE FACING FRAMES OF DIFFERENT BANKS, on every run that plays games as the Genesis: poses
# read from the data pack, each taking its colours from the bank its frame's pieces name
# (`bank_bit:`, `colors:` a whole slot), and many sprites facing the same poses. A retail game's
# sprite changes palette line with its frame, since the line is two bits of each piece's entry in
# the sprite table; here each pose is shown in its own bank's colours, and a sprite told to follow
# its lists shows what each bank holds now.
class TestPackPoseBankColorsOnTheGenesis < Minitest::Test
  include PackPoseBankColorGames

  # Two sprites that each face both frames, :still at (40, 40) showing the frame of bank 1 and
  # :turned at (80, 40) showing the frame of bank 2. The block is handed both, and the lists their
  # poses are drawn from as `draw_with` takes them to follow.
  private def two_sprites_facing_both_frames(folder, &more)
    test = self
    game_of(folder) do |pack|
      test.declare_poses_for(self, pack)
      facing = { first: :first, second: :second }
      still = sprite :still, at: [40, 40], facing: facing
      turned = sprite :turned, at: [80, 40], facing: facing
      turned.face :second
      lists = facing.values.map { |pose| colors_name_of(pose) }.uniq.to_h { |list| [list, list] }
      instance_exec(still, turned, lists, &more) if more
    end
  end

  def test_each_sprite_shows_the_frame_it_faces_in_the_colors_of_that_frames_bank
    Dir.mktmpdir do |folder|
      screen = game_player.run(two_sprites_facing_both_frames(folder), frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the sprite facing the frame of bank 1, left piece")
      assert_tile_drawn_in(BANKS[1], screen, 1, 48, 40, "the sprite facing the frame of bank 1, right piece")
      assert_tile_drawn_in(BANKS[2], screen, 0, 80, 40, "the sprite facing the frame of bank 2, left piece")
      assert_tile_drawn_in(BANKS[2], screen, 1, 88, 40, "the sprite facing the frame of bank 2, right piece")
    end
  end

  def test_sprites_following_their_frames_lists_show_what_the_bank_of_the_frame_showing_holds
    other = see_through_first(OTHER)
    Dir.mktmpdir do |folder|
      program = two_sprites_facing_both_frames(folder) do |still, turned, lists|
        colors :other, other
        still.draw_with lists
        turned.draw_with lists
        recolor :palette_2, :other
      end
      screen = game_player.run(program, frames: 5).screen

      assert_tile_drawn_in(OTHER, screen, 0, 80, 40, "the frame of bank 2, whose list holds :other")
      assert_tile_drawn_in(OTHER, screen, 1, 88, 40, "the frame of bank 2, right piece")
      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the frame of bank 1, whose list was not changed")
    end
  end
end
