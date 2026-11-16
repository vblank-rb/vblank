# frozen_string_literal: true

require "test_helper"
require "pack_table_tile_background_games"

# A TEXT LAYER OF 256 COLOURS FROM THE DATA PACK: more tiles than a byte names, some turned, under
# a map of map cells or of the Advance's own two-byte cells, whose bank bits mean nothing there
# (PackTableTileBackgroundGames). The answer key is the same background the game draws itself.
#
# A tile of 256 colours is the Advance's and not the Color's or the Genesis's, so these play on
# the Advance's runs alone.
class TestPackTableTileBackgroundsOnTheAdvance < Minitest::Test
  include PackTableTileBackgroundGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  private def assert_shows_as_the_drawn_one(what, frames: [2, 4], **how, &more)
    Dir.mktmpdir do |folder|
      from = table_tile_original(folder)
      whole, file = table_tile_pack_game_and_file(from, **how, &more)
      drawn = table_tile_drawn_game(&more)

      frames.each do |count|
        shown = game_player.run(drawn, frames: count).screen
        assert_operator shown.to_a.flatten.uniq.length, :>, 200, "#{what}: the drawn one shows the layer"
        assert_equal shown.to_a, game_player.run(whole, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the layer from the pack shows what the drawn one shows"
      end
      left_out, = table_tile_pack_game_and_file(from, options: LEFT_OUT, **how, &more)
      frames.each do |count|
        assert_equal game_player.run(drawn, frames: count).screen.to_a,
                     game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the layer read as the game starts shows what the drawn one shows"
      end
    end
  end

  def test_the_drawn_one_uses_more_than_256_tiles_some_turned
    cells = WORDS.map { |word| PackTableTileBackgroundGames.cell_of(word) }

    assert_operator cells.map(&:tile).reject(&:zero?).uniq.length, :>, 256
    assert(cells.any?(&:mirrored) && cells.any?(&:upside_down))
  end

  def test_a_map_of_map_cells_shows_as_the_drawn_one
    assert_shows_as_the_drawn_one("map cells") { |_layer| game_loop { wait_vblank } }
  end

  def test_a_map_of_map_cells_scrolled_shows_as_the_drawn_one
    assert_shows_as_the_drawn_one("map cells, scrolled", frames: [2, 6]) do |layer|
      game_loop do
        wait_vblank
        layer.scroll_by 3, 1
      end
    end
  end

  # The bank bits of the Advance's own cell are not read under tiles of 256 colours, on the
  # console or here.
  def test_a_map_of_the_advances_two_byte_cells_shows_as_the_drawn_one
    assert_shows_as_the_drawn_one("two-byte cells", map: :two_byte_cells) { |_layer| game_loop { wait_vblank } }
  end
end
