# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# THE PALETTES OF POSES READ FROM A DATA PACK, each drawn in the bank its frame names, in the Genesis's
# own colour memory. A sprite facing frames of two banks follows both banks' lists; the game changes
# one and never the other. The pose of the bank never changed is cut in its list's order, as a sprite
# told `draw_with` that one list is, so the two share one of the console's four palettes.
class TestGenesisPackPosePalettes < Minitest::Test
  include PackPoseBankColorGames

  def test_a_followed_bank_the_game_never_changes_shares_a_palette_with_a_sprite_drawn_with_it
    other = see_through_first(OTHER)
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        test.declare_poses_for(self, pack)
        colors :other, other
        facing = { first: :first, second: :second }
        turned = sprite :turned, at: [80, 40], facing: facing
        turned.draw_with(facing.values.map { |pose| colors_name_of(pose) }.uniq.to_h { |list| [list, list] })
        image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
        sprite(:dot, at: [40, 40]).draw_with :palette_1
        recolor :palette_2, :other
      end
      colors = played(program, frames: 10)
      filled = (0...4).count { |line| colors[(line * 16) + 1, 15].any?(&:nonzero?) }

      assert_equal 2, filled, "palettes holding colours: one for bank 1's list, one for bank 2's"
    end
  end

  private

  # The 64 words of the console's colour memory after +frames+ of +program+ built as a cartridge.
  def played(program, frames:)
    genesis = program.copy.tap { |copy| copy.console = :genesis }
    rom = VBlank::Console.for(:genesis).builder.cartridge_for(genesis, title: "POSES")
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.gen") do |core|
      frames.times { core.run_frame }
      core.cram.unpack("v*")
    end
  end

  # +colors+ as a `colors` list, its first place see-through.
  def see_through_first(colors) = colors.each_with_index.map { |color, at| at.zero? ? :transparent : color }
end
