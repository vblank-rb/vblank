# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# The colour tables of a sprite whose poses follow their lists, in the PlayStation's video RAM. A
# colour table is a row of 16 or 256 entries under the screen's pages (PS1::TextureMemory), and the
# graphics chip reads a sprite's texture through whichever table its drawing names, a background's
# as readily as one of the sprites' own.
class TestPS1PoseColorLists < Minitest::Test
  include PoseColorListGames

  # The lines of video RAM the tables are kept in (TextureMemory::TABLE_LINES), and its width.
  TABLE_LINES = VBlank::IR::Backends::PS1::TextureMemory::TABLE_LINES
  VRAM_WIDTH = VBlank::Console::PS1Hardware::VRAM_WIDTH

  # A list the game never changes, followed by a sprite and a background, is read through one table
  # the background's, which holds :warm's colours for good. :cold, which the game changes, has the
  # table of its own the sprites read it through. Given a table of its own, the pose of :warm would
  # make a third.
  def test_a_followed_list_the_game_never_changes_shares_the_backgrounds_table
    assert_equal 2, tables_after(followed_beside_background_game, frames: 10).length,
                 "colour tables: the background's, and the sprites' table of :cold"
  end

  private

  # The colour tables holding colours in video RAM after +frames+ of +program+ built as a PS-X EXE: each
  # 16 halfwords of the lines for tables that is not all nought.
  def tables_after(program, frames:)
    ps1 = program.copy.tap { |copy| copy.console = :ps1 }
    exe = VBlank::Console.for(:ps1).builder.cartridge_for(ps1, title: "POSES")
    VBlank::Diagnostics::Emulator.with_cartridge(exe, file_name: "game.exe") do |core|
      frames.times { core.run_frame }
      halfwords = core.vram.unpack("v*")
      TABLE_LINES.flat_map do |line|
        (0...VRAM_WIDTH).step(16).filter_map do |x|
          entries = halfwords[(line * VRAM_WIDTH) + x, 16]
          entries if entries.any?(&:nonzero?)
        end
      end
    end
  end
end
