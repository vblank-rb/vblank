# frozen_string_literal: true

require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# A POSE IN THE BANK ITS FRAME NAMES, ITS PACK LEFT OUT: what the games of PackPoseBankColorGames
# (test/all/vblank/builder/test_pack_pose_bank_colors.rb) do built with `pack_at_start: true` beyond
# what the registry holds alike (PackGames::PosesInBankColors, test/pack_games.rb): a frame whose
# pieces name two banks, which the build that holds the pack refuses, and one sprite facing frames of
# two banks that follows each one's list, which only a console that follows such lists plays.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackPoseBankColorsAtStartTests
  include PackPoseBankColorGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # THE FILE IS THE PLAYER'S, so a frame whose pieces name two banks does not stop the game: the
  # pose is drawn whole in the bank its front piece names, here bank 1.
  def test_a_frame_of_two_banks_is_drawn_in_its_front_pieces_bank_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      # The pack file of a game naming the same frame, which the build that holds the pack takes
      # as a pose of each bank's pieces.
      _, file = game_and_file_of(folder) do |pack|
        frame = pack[:frames].frame(IN_TWO_BANKS, layout: FRAME)
        image :near, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 1
        image :far, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 3
      end
      program, = game_and_file_of(folder, options: LEFT_OUT) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], size: [16, 8]
        sprite :mixed, at: [40, 40]
      end
      screen = game_player.hand_file(file).run(program, frames: 4).screen

      [[0, 40], [1, 48]].each do |tile, at_x|
        TILES.fetch(tile).each_with_index do |place, at|
          assert_equal BANKS[1].fetch(place), screen.pixel(at_x + (at % 8), 40 + (at / 8)), "tile #{tile}, pixel #{at}"
        end
      end
    end
  end

  # One sprite that can face the frame of bank 1 or of bank 2, following the list of each, as the
  # Genesis's own games change a sprite's line of colours with its frame. The list of bank 2 is
  # told to hold other colours, and the sprite, facing that frame, shows them.
  def test_a_sprite_facing_frames_of_two_banks_follows_the_list_its_frame_picks_with_the_pack_left_out
    test = self
    other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }
    Dir.mktmpdir do |folder|
      programs = [VBlank::Cartridge::Options.new, LEFT_OUT].map do |options|
        program, file = game_and_file_of(folder, options: options) do |pack|
          test.declare_poses_for(self, pack, size: [16, 8])
          colors :other, other
          facing = { first: :first, second: :second }
          turned = sprite :turned, at: [80, 40], facing: facing
          lists = facing.values.map { |pose| colors_name_of(pose) }.uniq.to_h { |list| [list, list] }
          turned.draw_with lists
          turned.face :second
          recolor :palette_2, :other
        end
        [program.copy.tap { |copy| copy.console = :genesis }, file]
      end
      (whole, file), (left_out, _) = programs
      wanted = game_player.run(whole, frames: 6).screen
      shown = game_player.hand_file(file).run(left_out, frames: 6).screen

      assert_equal wanted.to_a, shown.to_a
      TILES.fetch(0).each_with_index do |place, at|
        assert_equal OTHER.fetch(place), shown.pixel(80 + (at % 8), 40 + (at / 8)), "the frame of bank 2, pixel #{at}"
      end
    end
  end
end
