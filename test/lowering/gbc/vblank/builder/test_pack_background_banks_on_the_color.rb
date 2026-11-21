# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A background from the data pack in banks of four colours, as the Color's cartridge holds it. The
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

  # A told cell that draws nothing shows only the backdrop, as an empty cell does, so it costs no
  # list of its own: the screen in all eight banks, every bank walked up from black, still fits
  # the eight with a see-through cell told beside a drawn one, and both written over the map. The
  # checked run holds every pass to the interpreter.
  def test_a_told_cell_that_draws_nothing_takes_no_list_of_its_own
    Dir.mktmpdir do |folder|
      from = color_original(folder, EIGHT_BANKS_SCREEN)
      game_player.run(eight_banks_with_a_blank_told_cell(from), frames: COLOR_WALK_STEPS + 4)
    end
  end

  # The eight-bank screen walked up from black, told a cell of tile 0 (which draws nothing) and one
  # of tile 1, both in bank 3: the blank one is written over a drawn cell on the second pass, and
  # the drawn one over the next on the third. With +in_scene+ the screen is a scene's, and a second
  # scene, never shown, draws from HUT_LISTS.
  private def eight_banks_with_a_blank_told_cell(from, in_scene: false)
    shown = EIGHT_BANKS_SCREEN
    hut_lists = HUT_LISTS
    blank = VBlank::Original::MapCell::Cell.new(tile: 0, bank: 3)
    drawn = VBlank::Original::MapCell::Cell.new(tile: 1, bank: 3)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: shown.video.length
        slots.colors :palette, at: COLORS_AT, count: shown.palette.length
        slots.map_cells :map, count: shown.cells.length
        slots.fill_from_copy do |copy, filled|
          repeat(shown.cells.length) do |at|
            filled[:map].write_cell(at, tile: copy.byte(COLOR_TILE_MAP_AT + at), bank: copy.byte(COLOR_ATTRIBUTES_AT + at) & 7)
          end
        end
      end
      step = var :step, 0
      field = lambda do
        world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: shown.across,
                                   set_cells: [blank, drawn]
        walks = Array.new(8) { |at| [:"palette_#{at}", color_walk(:"palette_#{at}", from: :black, steps: COLOR_WALK_STEPS)] }.to_h
        world.draw_with(walks, showing: step)
        world.set_cell 3, 0, blank if step == 2
        world.set_cell 4, 0, drawn if step == 3
      end
      unless in_scene
        field.call
        next game_loop do
          wait_vblank
          step.store!(step + 1)
        end
      end

      # A bar every scene shows, of a tile that draws nothing: asked for before any scene's lists.
      image :bar_blank, width: 8, height: 8, colors: [:transparent, :white], places: Array.new(64, 0)
      tiles :bar_tiles, { "." => :bar_blank }
      status_bar :bar, tiles: :bar_tiles, map: ["." * 20, "." * 20], top: screen_height - 16
      hut_lists.each_with_index do |list, at|
        image :"hut_#{at}", width: 8, height: 8, colors: list, places: Array.new(64) { |i| 1 + ((i + at) % 3) }
      end
      tiles :hut_tiles, { "a" => :hut_0, "b" => :hut_1 }
      scene(:field) { field.call }
      scene(:hut) { background :hut, tiles: :hut_tiles, map: ["ab"] }
      var :state, 0
      game_loop do
        wait_vblank
        step.store!(step + 1)
        case_var(:state) do
          when_val 0, :field
          when_val 1, :hut
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The same in a scene of its own, beside a scene drawn from two other lists: ten lists between
  # them, so each scene brings its own lists in as it comes up. Every scene shows a bar whose tile
  # draws nothing too, asked for before any scene's lists are, and neither it nor the told cell
  # takes a list: the scene's eight banks still fit the eight.
  def test_a_told_cell_that_draws_nothing_takes_no_list_in_a_scene_bringing_its_own_lists
    Dir.mktmpdir do |folder|
      from = color_original(folder, EIGHT_BANKS_SCREEN)
      game_player.run(eight_banks_with_a_blank_told_cell(from, in_scene: true), frames: COLOR_WALK_STEPS + 4)
    end
  end

  # Two lists of four colours for the other scene, unlike any of the eight banks.
  HUT_LISTS = [[:transparent, 0x001F, 0x03E0, 0x7C00], [:transparent, 0x7FFF, 0x1234, 0x4321]].freeze

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
