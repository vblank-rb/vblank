# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND DRAWN FROM THE ORIGINAL'S OWN TILES, MAP AND COLOURS (Builder::PackBackgrounds), read
# from a made-up original in the layout of the console it is for (PackBackgroundGames). The answer
# key is the made-up data itself: each cell of the map names a tile, a bank of colours and a turn,
# and the screen must show that tile's places in that bank's colours, turned that way.
class TestPackBackgrounds < Minitest::Test
  include PackBackgroundGames

  # The colour at (x, y) of a cell drawn from +places+ (rows of +side+) in +bank+, turned as asked.
  private def cell_color(places, side, x, y, bank, mirrored: false, upside_down: false)
    x = side - 1 - x if mirrored
    y = side - 1 - y if upside_down
    BANKS.fetch(bank).fetch(places.fetch((y * side) + x))
  end

  private def assert_cell(screen, places, side, at_x, at_y, bank, **turn)
    side.times do |y|
      side.times do |x|
        place = places.fetch(((upside(y, side, turn) * side) + across(x, side, turn)))
        next if place.zero?

        assert_equal cell_color(places, side, x, y, bank, **turn), screen.pixel(at_x + x, at_y + y),
                     "the pixel at (#{x}, #{y}) of the cell at (#{at_x}, #{at_y}), #{turn.inspect}"
      end
    end
  end

  private def upside(y, side, turn) = turn[:upside_down] ? side - 1 - y : y
  private def across(x, side, turn) = turn[:mirrored] ? side - 1 - x : x

  def test_an_advance_originals_cells_show_their_tile_bank_and_turn
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1), ADVANCE_CELL.(1, mirrored: true), ADVANCE_CELL.(2, bank: 1, upside_down: true),
               ADVANCE_CELL.(3, bank: 1, mirrored: true, upside_down: true),
               ADVANCE_CELL.(0), ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(1, bank: 1)]
      program = pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 4, cell: 8)
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
      assert_cell(screen, PLACES[1], 8, 8, 0, 0, mirrored: true)
      assert_cell(screen, PLACES[2], 8, 16, 0, 1, upside_down: true)
      assert_cell(screen, PLACES[3], 8, 24, 0, 1, mirrored: true, upside_down: true)
      assert_cell(screen, PLACES[1], 8, 8, 8, 0)
      assert_cell(screen, PLACES[1], 8, 24, 8, 1)
      assert_equal screen.pixel(100, 100), screen.pixel(3, 11), "a cell of tile 0, which draws nothing, shows what is behind"
    end
  end

  # A Super Nintendo cell of 16x16 pixels is the four tiles t, t + 1, t + 16 and t + 17 of its video
  # memory, and turning it turns the whole cell.
  def test_a_super_nintendo_originals_big_cells_are_four_tiles_of_its_video_memory
    Dir.mktmpdir do |folder|
      video = Array.new(18) { |at| PLACES.fetch(at % 4) }
      video[0] = PLACES[1]
      video[1] = PLACES[2]
      video[16] = PLACES[3]
      video[17] = PLACES[1]
      tiles = video.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
      words = [SNES_CELL.(0), SNES_CELL.(0, bank: 1, mirrored: true)]
      program = pack_game(original(folder, :snes, tiles, words), 18, words, across: 2, cell: 16)
      screen = game_player.run(program, frames: 3).screen
      big = Array.new(16) do |y|
        Array.new(16) { |x| video.fetch(((y / 8) * 16) + (x / 8)).fetch(((y % 8) * 8) + (x % 8)) }
      end.flatten

      assert_cell(screen, big, 16, 0, 0, 0)
      assert_cell(screen, big, 16, 16, 0, 1, mirrored: true)
    end
  end

  def test_a_genesis_originals_cells_show_their_tile_bank_and_turn
    Dir.mktmpdir do |folder|
      words = [GENESIS_CELL.(1), GENESIS_CELL.(1, mirrored: true), GENESIS_CELL.(2, bank: 1, upside_down: true),
               GENESIS_CELL.(3, bank: 1, mirrored: true, upside_down: true)]
      tiles = PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
      program = pack_game(original(folder, :genesis, tiles, words), 4, words, across: 4, cell: 8)
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
      assert_cell(screen, PLACES[1], 8, 8, 0, 0, mirrored: true)
      assert_cell(screen, PLACES[2], 8, 16, 0, 1, upside_down: true)
      assert_cell(screen, PLACES[3], 8, 24, 0, 1, mirrored: true, upside_down: true)
    end
  end

  # Each bank is a list of colours named for its slot, so a game draws the background with other
  # colours by place as it would one of its own.
  def test_a_bank_is_a_list_of_colours_named_for_its_slot
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }
      program = pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8) do |world|
        colors :other, other
        world.draw_with({ palette_0: :other })
        game_loop { wait_vblank }
      end
      screen = game_player.run(program, frames: 3).screen
      place = PLACES[1][1]

      assert_equal other.fetch(place), screen.pixel(1, 0), "the pixel at (1, 0), drawn with :other in place of :palette_0"
    end
  end

  # A game showing one cell of tile 1 from bank 0, its slot of colours holding two banks, and
  # whatever the block says, then a loop that only waits.
  private def game_drawn_from_bank_0(folder, &more)
    words = [ADVANCE_CELL.(1)]
    pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8) do |world|
      instance_exec(world, &more)
      game_loop { wait_vblank }
    end
  end

  # +colors+ as a `colors` list, its first place see-through.
  private def see_through_first(colors) = colors.each_with_index.map { |color, at| at.zero? ? :transparent : color }

  # WHICH BANKS A MAP DRAWS FROM IS IN THE PLAYER'S COPY, so a game names every bank its screen
  # fades, as the original walks every bank of the console's colours, and the banks this map
  # does not use change nothing.
  def test_a_bank_the_map_does_not_use_is_stepped_with_the_ones_it_does
    Dir.mktmpdir do |folder|
      first = see_through_first(OTHER)
      second = see_through_first(LATER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :first, first
        colors :second, second
        step = var :step, 1
        world.draw_with({ palette_0: %i[first second], palette_1: %i[first second] }, showing: step)
      end
      screen = game_player.run(program, frames: 3).screen

      assert_equal second.fetch(PLACES[1][1]), screen.pixel(1, 0), "bank 0's tile at step 1, beside bank 1 that no cell uses"
    end
  end

  def test_a_background_told_only_banks_its_map_does_not_use_is_shown_as_drawn
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :other, other
        world.draw_with({ palette_1: :other })
      end
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
    end
  end

  # `recolor` of a bank the map does not use reaches what is drawn with it, a sprite here, and
  # leaves the background as drawn.
  def test_a_bank_the_map_does_not_use_is_recolored_beside_the_background
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :other, other
        world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
        image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
        dot = sprite :dot, at: [40, 40]
        dot.draw_with :palette_1
        recolor :palette_1, :other
      end
      screen = game_player.run(program, frames: 4).screen

      assert_equal other.fetch(2), screen.pixel(41, 41), "the sprite drawn with bank 1, which holds :other"
      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
    end
  end

  # Every pixel of the 8x8 cell at (+at_x+, 0) drawn from +places+ shows +list+'s colour at its place.
  private def assert_cell_drawn_with(screen, places, at_x, list, message)
    64.times do |at|
      next if places.fetch(at).zero?

      assert_equal list.fetch(places.fetch(at)), screen.pixel(at_x + (at % 8), at / 8), "#{message}, at (#{at % 8}, #{at / 8})"
    end
  end

  # A SCREEN THAT FADES EVERY BANK AT ONCE: a map with cells in two banks, both told `recolor`, each
  # on a pass of its own. The background follows both, a cell showing what its own bank holds.
  def test_a_background_follows_two_banks_the_game_recolors
    Dir.mktmpdir do |folder|
      first = see_through_first(OTHER)
      second = see_through_first(LATER)
      words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)]
      program = pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 2, cell: 8) do |world|
        colors :first, first
        colors :second, second
        world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
        %i[palette_0 palette_1].each_with_index do |bank, at|
          image :"dot_#{at}", width: 8, height: 8, places: Array.new(64, 2), colors: bank
          sprite(:"dot_#{at}", at: [40 + (at * 20), 40]).draw_with bank
        end
        pass = var :pass, 0
        game_loop do
          pass += 1
          recolor :palette_0, :first if pass >= 3
          recolor :palette_1, :second if pass >= 5
        end
      end
      shown_after = ->(pass) { game_player.run(program, frames: pass + framework_drawing_lag).screen }

      early = shown_after.(2)
      assert_cell(early, PLACES[1], 8, 0, 0, 0)
      assert_cell(early, PLACES[2], 8, 8, 0, 1)
      between = shown_after.(3)
      assert_cell_drawn_with(between, PLACES[1], 0, first, "bank 0's cell once bank 0 holds :first")
      assert_cell(between, PLACES[2], 8, 8, 0, 1)
      late = shown_after.(5)
      assert_cell_drawn_with(late, PLACES[1], 0, first, "bank 0's cell, still :first")
      assert_cell_drawn_with(late, PLACES[2], 8, second, "bank 1's cell once bank 1 holds :second")
      assert_equal [first.fetch(2), second.fetch(2)], [late.pixel(41, 41), late.pixel(61, 41)], "the sprites drawn with each bank"
    end
  end

  def test_a_list_that_is_not_a_bank_of_the_slot_is_still_refused
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      error = assert_raises(ArgumentError) do
        game_drawn_from_bank_0(folder) do |world|
          colors :other, other
          world.draw_with({ other: :palette_0 })
        end
      end

      assert_includes error.message, "none of its tiles is drawn from :other"
    end
  end

  def test_a_bank_the_map_does_not_use_drawn_with_no_list_of_colors_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_drawn_from_bank_0(folder) { |world| world.draw_with({ palette_1: :ghost }) }
      end

      assert_includes error.message, ":ghost, which is not a list of colors"
    end
  end

  def test_a_map_whose_cells_do_not_fill_its_rows_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)] * 6
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 4, cell: 8)
      end

      assert_includes error.message, "across:"
    end
  end

  def test_a_big_cell_of_an_original_whose_cells_are_one_tile_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 16)
      end

      assert_includes error.message, "cell:"
    end
  end

  # A BUILD THAT READS ITS PACK AS THE GAME STARTS knows a bank's name and none of its colours.
  # What it shows, a bank walked, recoloured or drawn in among it, is PackBackgroundAtStartTests's,
  # on the runs that are handed a file. These are what it refuses as the game is built.
  private def left_out_refusal(folder, &uses_bank)
    words = [ADVANCE_CELL.(1)]
    options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
    assert_raises(ArgumentError) do
      pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8, options: options, &uses_bank)
    end
  end

  # The build cannot find a pixel's place in colours it does not hold, which drawing a picture
  # given as colours with another list needs. Drawn as it is, such a picture shows its own
  # colours (PackGames::ColorLists holds that to the all-in-one build).
  def test_a_picture_of_colors_in_a_bank_read_as_the_game_starts_drawn_with_another_list_is_refused
    Dir.mktmpdir do |folder|
      error = left_out_refusal(folder) do |_world|
        image :mark, width: 8, height: 8, colors: :palette_1, data: Array.new(64, :red)
        sprite(:mark, at: [40, 40]).draw_with :palette_0
      end

      assert_includes error.message, "image :mark"
      assert_includes error.message, "as the game starts"
    end
  end

  def test_a_game_list_named_as_a_bank_read_as_the_game_starts_is_refused
    Dir.mktmpdir do |folder|
      error = left_out_refusal(folder) { |_world| colors :palette_0, %i[transparent red green blue] }

      assert_includes error.message, ":palette_0"
    end
  end

  def test_a_cell_changed_on_a_background_read_as_the_game_starts_is_refused
    Dir.mktmpdir do |folder|
      error = left_out_refusal(folder) do |world|
        tile = var :tile, 0
        game_loop do
          world.set_tile 0, 0, tile
          wait_vblank
        end
      end

      assert_includes error.message, "set_tile"
      assert_includes error.message, "as the game starts"
    end
  end

  def test_a_map_of_more_cells_than_a_build_reading_its_pack_keeps_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)] * (256 * 129)
      options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 256, cell: 8, options: options)
      end

      assert_includes error.message, "cells"
    end
  end

  def test_a_map_that_draws_nothing_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(0)] * 4
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 2, cell: 8)
      end

      assert_includes error.message, "draws nothing"
    end
  end

  def test_a_game_list_named_as_a_bank_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      b = Builder.new
      error = assert_raises(ArgumentError) do
        b.instance_eval do
          screen :tiled
          colors :palette_0, %i[transparent red green blue]
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: 1, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 1
        end
      end

      assert_includes error.message, ":palette_0"
    end
  end

  def test_a_cell_drawing_a_tile_past_the_slot_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(9)]
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8)
      end

      assert_includes error.message, "tile 9"
    end
  end
end
