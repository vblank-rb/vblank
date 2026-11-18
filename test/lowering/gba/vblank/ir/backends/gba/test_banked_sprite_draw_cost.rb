# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"

# WHAT A SPRITE ENTRY NAMING ITS OWN BANK COSTS THE DRAW, measured in the emulator. A sprite of a pose
# of several banks (`image ..., banks:`) has each entry name its piece's bank in attribute 2 (GBATEK,
# "LCD OBJ - OAM Attributes", bits 12-15), read from the pose table beside the piece's pose word: one
# more load and one OR an entry, where a sprite of one bank folds its bank into a number written once.
# The same game is built twice, sixteen sprites each stepping between a pose of two entries and that
# pose turned round, every pass, so each reads its pose table: once a frame of the pack in banks 1 and
# 3, once a picture of two pieces in one list, wider than any one entry so the cut keeps them two
# (SpriteCut#best_grid). What the two differ by is the bank's read and OR for each entry.
class TestBankedSpriteDrawCost < Minitest::Test
  include PackPoseBankColorGames

  FRAME_CYCLES = 280_896 # A frame's cycles: 228 lines of 1232
  SPRITES = 16
  ENTRIES = SPRITES * 2 # Two entries a pose

  # Measured: see the commit that added this. A load from the cartridge's table and an OR is a few
  # cycles; the bound leaves room for the cartridge's wait states and nothing more.
  def test_an_entry_naming_its_own_bank_costs_under_6_cycles_more
    Dir.mktmpdir do |folder|
      banked = awake_cycles(folder, banked: true)
      plain = awake_cycles(folder, banked: false)
      more = (banked - plain) / ENTRIES

      assert_operator more, :<, 6, "an entry naming its own bank costs #{more.round(1)} cycles more (#{banked.round} against #{plain.round} a frame)"
    end
  end

  # The cycles a frame the game of SPRITES sprites spends awake, each stepping between a pose and it
  # turned round: the frame of banks 1 and 3, or a picture of two pieces in bank 1's colours.
  private def awake_cycles(folder, banked:)
    test = self
    program = game_of(folder) do |pack|
      if banked
        image :pose, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                     colors: pack[:palette], banks: [1, 3]
      else
        image :pose, pieces: [[0, 0, TILES[0]], [64, 0, TILES[1]]], colors: test.bank_one_list
      end
      SPRITES.times { |at| sprite :"walker_#{at}", at: [8 + ((at % 8) * 28), 24 + ((at / 8) * 40)], frames: [:pose, mirror(:pose)], rate: 1 }
    end
    rom = assemble_rom(program, name: "COST")
    (1 - VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).idle_share) * FRAME_CYCLES
  end

  # Bank 1's colours as a list of the game's own, its first see-through. Public, since a game's block
  # calls back through it.
  def bank_one_list = BANKS[1].each_with_index.map { |color, at| at.zero? ? :transparent : color }
end
