# frozen_string_literal: true

require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"

# A CELL OF A BACKGROUND FROM THE DATA PACK WRITTEN `now: true` SHOWS WHAT IT SHOWS WRITTEN WITHOUT
# IT, once the frame it was written on is drawn: by a told number and by a place in a slot of told
# cells, each written in the game and worked out as it runs, and blanked again. When it shows is
# the Color cartridge's (test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_pack_cell_shown_now.rb).
# Played by each console that writes a cell while it draws (test/console/gba/ and gbc/); the Super
# Nintendo and the Genesis refuse it (TestPackBackgroundSetCell).
module PackCellWrittenNowTests
  include PackBackgroundSetCellGames

  def test_told_cells_written_now_show_as_written_for_the_gap
    Dir.mktmpdir do |folder|
      [3, 8].each do |frames|
        assert_equal game_player.run(map_cells_text_game(folder, :gbc, blank_at: 4).first, frames: frames).screen.to_a,
                     game_player.run(map_cells_text_game(folder, :gbc, blank_at: 4, now: true).first, frames: frames).screen.to_a,
                     "after #{frames} frames"
      end
    end
  end

  def test_places_in_a_slot_written_now_show_as_written_for_the_gap
    Dir.mktmpdir do |folder|
      [3, 8].each do |frames|
        assert_equal game_player.run(slot_told_text_game(folder, :gbc, blank_at: 4).first, frames: frames).screen.to_a,
                     game_player.run(slot_told_text_game(folder, :gbc, blank_at: 4, now: true).first, frames: frames).screen.to_a,
                     "after #{frames} frames"
      end
    end
  end
end
