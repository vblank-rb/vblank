# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE DATA PACK IN BANKS OF FOUR COLOURS, as the Color's cartridge holds it. The
# original keeps eight lists of four colours for its backgrounds, and each cell names one by its
# bank: every tile of a bank is drawn from that list, the bank's colours at the bank's places,
# however many of them the tile draws. So the cartridge holds a list for each bank the map uses,
# the backdrop first where the original's see-through place is, and a screen of seven banks fits
# in the Color's eight. That it shows the decoded cells is TestPackBackgrounds's, on every run.
class TestPackBackgroundBanksOnTheColor < Minitest::Test
  include PackBackgroundGames

  GBC = VBlank::IR::Backends::GBC

  # One bank more than the Color holds lists for.
  NINE_BANKS = 9

  # A map in all eight banks, each tile drawing two of its bank's three places, fits only with one
  # list for each bank: a list for each tile's own colours would be sixteen. It shows the decoded
  # cells, and walked up from black by the banks' names it is held to the interpreter every pass.
  def test_a_screen_in_all_eight_banks_fits_the_colors_eight_lists
    Dir.mktmpdir do |folder|
      from = color_original(folder, EIGHT_BANKS_SCREEN)
      program, = color_cells_game_and_file(from, color_screen: EIGHT_BANKS_SCREEN)
      walked, = color_cells_game_and_file(from, walked: true, color_screen: EIGHT_BANKS_SCREEN)
      by_hand = color_cells_drawn_by_hand(color_screen: EIGHT_BANKS_SCREEN)

      assert_equal map_pixels(Reference.new.run(by_hand, frames: 3).screen, EIGHT_BANKS_SCREEN),
                   map_pixels(game_player.run(program, frames: 3).screen, EIGHT_BANKS_SCREEN)
      game_player.run(walked, frames: COLOR_WALK_STEPS + 2)
    end
  end

  # A map whose cells name nine banks needs nine lists at once, one more than the Color holds,
  # and the refusal names the eight. The made-up original holds eight banks of colours; the ninth
  # is read from past them, where the copy is empty.
  def test_a_screen_in_nine_banks_is_refused_naming_the_eight
    Dir.mktmpdir do |folder|
      from = color_original(folder, EIGHT_BANKS_SCREEN)
      b = Builder.new
      b.instance_eval do
        screen :tiled
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: SUBSET_VIDEO.length
          slots.colors :palette, at: COLORS_AT, count: NINE_BANKS * COLOR_BANK_SIZE
          slots.map_cells :map, count: NINE_BANKS
          slots.fill_from_copy { |_copy, filled| repeat(NINE_BANKS) { |at| filled[:map].write_cell(at, tile: 1, bank: at) } }
        end
        background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: NINE_BANKS
        game_loop { wait_vblank }
      end
      b.finalize_program
      program = b.program
      program.console = :gbc
      error = assert_raises(GBC::LoweringError) { GBC.new.build(program) }

      assert_match(/more than the 8 lists of colours/, error.message)
    end
  end
end
