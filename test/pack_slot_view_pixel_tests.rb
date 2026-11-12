# frozen_string_literal: true

require "pack_slot_view_games"

# PIXELS AND TABLES READ THROUGH VIEWS OF A SLOT OF TILES (DSL::PackSlot#as_pixels, #as_numbers),
# held to the same game holding them itself (PackSlotViewGames#table_and_pixels_game_and_file). The
# picture is a tile of 256 colours, five of them in one 8x8 square over black, which a Game Boy Color
# cannot show (it keeps 4 colours in each square), so each console that can has a test file that
# includes these, and they are written once:
#
#   test/console/gba/vblank/dsl/test_pack_slot_view_pixels_on_the_advance.rb
#   test/console/snes/vblank/dsl/test_pack_slot_view_pixels_on_the_super_nintendo.rb
#   test/console/genesis/vblank/dsl/test_pack_slot_view_pixels_on_the_genesis.rb
#   test/console/ps1/vblank/dsl/test_pack_slot_view_pixels_on_the_playstation.rb
#
# What a game is told when a view cannot be made plays everywhere, in
# test/all/vblank/dsl/test_pack_slot_views.rb.
module PackSlotViewPixelTests
  include PackSlotViewGames

  def test_pixels_and_tables_viewed_in_a_slot_of_tiles_show_as_the_game_holding_them
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      viewed, = table_and_pixels_game_and_file(from, views: true)
      held, = table_and_pixels_game_and_file(from, views: false)

      pictures = [2, 5, 9].map do |frames|
        shown = game_player.run(held, frames: frames).screen
        assert_equal shown.to_a, game_player.run(viewed, frames: frames).screen.to_a, "after #{frames} frames"
        shown.to_a
      end
      assert_equal 3, pictures.uniq.length, "the marks move from pass to pass"
    end
  end
end
