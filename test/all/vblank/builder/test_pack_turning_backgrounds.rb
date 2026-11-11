# frozen_string_literal: true

require "test_helper"
require "pack_turning_background_games"

# WHAT A GAME IS TOLD when it asks for a background of bytes from the data pack that cannot be
# made: a map of one byte a cell, or tiles of a byte a pixel (Builder::PackBackgrounds). What such
# a background shows, turned and resized, is
# test/console/gba/vblank/builder/test_pack_turning_backgrounds_on_the_advance.rb's, on the runs
# whose console turns a background.
class TestPackTurningBackgrounds < Minitest::Test
  include PackTurningBackgroundGames

  # The error of a game whose data pack names +slots+ (a block handed the slots) and whose
  # background is +background+ (a block handed the pack, run in the game).
  private def refusal(slots, options: VBlank::Cartridge::Options.new, &background)
    Dir.mktmpdir do |folder|
      from = turning_original(folder)
      assert_raises(ArgumentError) do
        VBlank::Builder.new(options: options).instance_eval do
          screen :tiled
          instance_exec(data_pack(from: from, version: "1", &slots), &background)
        end
      end
    end
  end

  BYTES = lambda do |slots|
    slots.tiles :pictures, at: TILES_AT, count: BYTE_TILES.length, colors: 256
    slots.numbers :cells, at: MAP_AT, count: CELLS.length, width: :byte, signed: false
    slots.colors :table, at: COLORS_AT, count: TABLE.length
  end

  def test_tiles_of_256_colors_under_a_map_of_two_byte_cells_are_refused
    slots = lambda do |named|
      named.tiles :pictures, at: TILES_AT, count: BYTE_TILES.length, colors: 256
      named.numbers :cells, at: MAP_AT, count: CELLS.length / 2, width: :half, signed: false
      named.colors :table, at: COLORS_AT, count: TABLE.length
    end
    error = refusal(slots) { |pack| background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: 16 }

    assert_includes error.message, "one byte wide"
  end

  def test_tiles_of_256_colors_with_fewer_colors_than_the_table_are_refused
    slots = lambda do |named|
      named.tiles :pictures, at: TILES_AT, count: BYTE_TILES.length, colors: 256
      named.numbers :cells, at: MAP_AT, count: CELLS.length, width: :byte, signed: false
      named.colors :table, at: COLORS_AT, count: 32
    end
    error = refusal(slots) { |pack| background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: SIDE }

    assert_includes error.message, "256 colors"
  end

  def test_cells_written_later_on_tiles_of_256_colors_are_refused
    error = refusal(BYTES) do |pack|
      background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: SIDE, set_cells: [1]
    end

    assert_includes error.message, "set_cells:"
  end

  # Its tiles are drawn from the whole table, so it has no list of colours to draw with others.
  def test_other_colors_for_tiles_of_256_colors_are_refused
    error = refusal(BYTES) do |pack|
      colors :dusk, %i[transparent red green blue]
      background(:layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: SIDE).draw_with :dusk
    end

    assert_includes error.message, ":layer"
  end

  def test_a_map_of_numbers_four_bytes_wide_is_refused
    slots = lambda do |named|
      named.tiles :pictures, at: TILES_AT, count: BYTE_TILES.length, colors: 256
      named.numbers :cells, at: MAP_AT, count: CELLS.length / 4, width: :word, signed: false
      named.colors :table, at: COLORS_AT, count: TABLE.length
    end
    error = refusal(slots) { |pack| background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: 16 }

    assert_includes error.message, "map:"
  end

  # A run of a slot of numbers is a background's map; a table takes a whole slot.
  def test_a_run_of_a_slot_of_numbers_given_to_a_table_is_refused
    error = refusal(BYTES) { |pack| table :cells, pack[:cells].numbers(4, 8) }

    assert_includes error.message, "some of the numbers"
  end

  def test_a_run_past_the_end_of_its_slot_is_refused
    error = refusal(BYTES) { |pack| pack[:cells].numbers(CELLS.length - 4, 8) }

    assert_includes error.message, "end inside the slot"
  end

  # A build that reads its pack as the game starts refuses the same things as it is built.
  def test_cells_written_later_on_tiles_of_256_colors_read_as_the_game_starts_are_refused
    options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
    error = refusal(BYTES, options: options) do |pack|
      background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: SIDE, set_cells: [1]
    end

    assert_includes error.message, "set_cells:"
  end
end
