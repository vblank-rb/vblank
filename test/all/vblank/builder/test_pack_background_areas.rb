# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE DATA PACK THAT WALKS BETWEEN AREAS: each area names its own slots of tiles,
# map and colours, as a port keeps each level's art, and `show_map` walks between them as it does
# between the tilesets of a background the game draws itself. The made-up Advance original keeps
# two areas: a town and a castle, each its own tiles, its own map and its own two banks of colours.
#
# The answer key is the same two areas drawn by hand: each cell of each map decoded here, from the
# Advance's hardware, into a picture of 8x8 in its bank's colours, turned as the cell says, and the
# two tilesets walked by the same `show_map`s.
module PackBackgroundAreaGames
  include PackBackgroundGames

  TOWN_MAP_AT = 0x20
  CASTLE_MAP_AT = 0x30
  TOWN_COLORS_AT = 0x40
  CASTLE_COLORS_AT = 0x80
  TOWN_TILES_AT = 0x100
  CASTLE_TILES_AT = 0x180
  COPY_SIZE = 0x200

  # Each area of the original: its tiles' places, its two banks of colours, and its map's cells, each
  # [tile, bank, mirrored, upside down], two to a row.
  Area = Data.define(:places, :banks, :cells, :map_at, :colors_at, :tiles_at)
  ACROSS = 2
  AREAS = {
    town: Area.new(places: PLACES, banks: BANKS,
                   cells: [[1, 0, false, false], [2, 1, true, false], [3, 0, false, false], [1, 1, false, true]],
                   map_at: TOWN_MAP_AT, colors_at: TOWN_COLORS_AT, tiles_at: TOWN_TILES_AT),
    castle: Area.new(places: [PLACES[0], PLACES[3], PLACES[1], PLACES[2]], banks: [OTHER, LATER],
                     cells: [[2, 1, false, false], [1, 0, false, true], [0, 0, false, false], [3, 1, true, true]],
                     map_at: CASTLE_MAP_AT, colors_at: CASTLE_COLORS_AT, tiles_at: CASTLE_TILES_AT)
  }.freeze

  VBlank::Testing::InRactors.share_constants(self)

  def self.advance_word(tile, bank, mirrored, upside_down)
    ADVANCE_CELL.(tile, bank: bank, mirrored: mirrored, upside_down: upside_down)
  end

  # The made-up original holding both areas.
  private def areas_original(folder)
    copy = "\0".b * COPY_SIZE
    AREAS.each_value do |area|
      copy[area.map_at, area.cells.length * 2] = area.cells.map { |cell| PackBackgroundAreaGames.advance_word(*cell) }.pack("v*")
      copy[area.colors_at, 64] = area.banks.flatten.pack("v*")
      copy[area.tiles_at, 128] = area.places.map(&LOW_HALF_FIRST).join
    end
    path = File.join(folder, "made_up_areas.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game reading both areas from the pack, built as +options+ say. The block, run on the
  # builder, is the game loop, handed the background. Hands back the program and the pack file the
  # build made (nil for a build that leaves its pack out).
  private def areas_game_and_file(from, options: VBlank::Cartridge::Options.new, &loop_body)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        AREAS.each do |name, area|
          slots.tiles :"#{name}_video", at: area.tiles_at, count: area.places.length
          slots.numbers :"#{name}_map", at: area.map_at, count: area.cells.length, width: :half, signed: false
          slots.colors :"#{name}_colors", at: area.colors_at, count: 32
        end
      end
      world = background :world, tiles: AREAS.keys.to_h { |name| [name, pack[:"#{name}_video"]] },
                                 map: AREAS.keys.to_h { |name| [name, pack[:"#{name}_map"]] },
                                 colors: AREAS.keys.to_h { |name| [name, pack[:"#{name}_colors"]] }, across: ACROSS
      instance_exec(world, &loop_body)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE ANSWER KEY: both areas drawn by hand, walked by the same loop.
  private def areas_drawn_by_hand(&loop_body)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      maps = AREAS.to_h do |name, area|
        area.banks.each_with_index { |bank, at| colors :"#{name}_bank_#{at}", bank }
        pictures = {}
        drawn = area.cells.map do |tile, bank, mirrored, upside_down|
          places = area.places.fetch(tile)
          next nil if places.all?(&:zero?)

          rows = places.each_slice(8).to_a
          rows = rows.map(&:reverse) if mirrored
          rows = rows.reverse if upside_down
          picture = :"#{name} cell #{pictures.length}"
          image picture, width: 8, height: 8, places: rows.flatten, colors: :"#{name}_bank_#{bank}"
          pictures[picture] = picture
        end
        tiles :"#{name}_by_hand", pictures
        [name, drawn.each_slice(ACROSS).to_a]
      end
      world = background :world, tiles: AREAS.keys.to_h { |name| [name, :"#{name}_by_hand"] }, map: maps
      instance_exec(world, &loop_body)
    end
    b.finalize_program
    b.program
  end

  # The game loop: the town on the first passes, the castle from the third, and the town again from
  # the sixth.
  def self.emit_walk(builder, world)
    builder.instance_eval do
      tick = var :tick, 0
      game_loop do
        tick += 1
        world.show_map :castle if tick == 3
        world.show_map :town if tick == 6
      end
    end
  end
end

class TestPackBackgroundAreas < Minitest::Test
  include PackBackgroundAreaGames

  private def screen_at(program, frames) = game_player.run(program, frames: frames).screen.to_a

  def test_each_area_shows_its_own_tiles_map_and_colors_from_the_pack
    by_hand = areas_drawn_by_hand { |world| PackBackgroundAreaGames.emit_walk(self, world) }
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder)) { |world| PackBackgroundAreaGames.emit_walk(self, world) }

      { 2 => "the town", 5 => "the castle, walked into", 9 => "the town, walked back to" }.each do |frames, what|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), what
      end
    end
  end

  def test_the_two_areas_show_different_pictures
    by_hand = areas_drawn_by_hand { |world| PackBackgroundAreaGames.emit_walk(self, world) }

    refute_equal screen_at(by_hand, 2), screen_at(by_hand, 5)
  end

  private def refusal_with(set_cells: nil, **given)
    Dir.mktmpdir do |folder|
      from = areas_original(folder)
      assert_raises(ArgumentError) do
        b = VBlank::Builder.new
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :town_video, at: TOWN_TILES_AT, count: 4
            slots.tiles :wide_video, at: TOWN_TILES_AT, count: 2, colors: 256
            slots.numbers :town_map, at: TOWN_MAP_AT, count: 4, width: :half, signed: false
            slots.numbers :byte_map, at: CASTLE_MAP_AT, count: 4, width: :byte, signed: false
            slots.colors :town_colors, at: TOWN_COLORS_AT, count: 32
            slots.colors :every_color, at: 0, count: 256
          end
          areas = given.transform_values { |by_area| by_area.transform_values { |slot| pack[slot] } }
          told = set_cells ? { set_cells: set_cells } : {}
          background :world, across: ACROSS, **told,
                             **{ tiles: pack[:town_video], map: pack[:town_map], colors: pack[:town_colors] }.merge(areas)
        end
      end
    end
  end

  def test_areas_named_differently_by_two_settings_are_a_friendly_error
    error = refusal_with(tiles: { town: :town_video, castle: :town_video }, map: { town: :town_map, keep: :town_map })

    assert_match(/the same areas/, error.message)
  end

  def test_areas_whose_maps_keep_a_cell_differently_are_a_friendly_error
    error = refusal_with(map: { town: :town_map, castle: :byte_map })

    assert_match(/:castle/, error.message)
    assert_match(/cell/, error.message)
  end

  def test_areas_whose_tiles_have_different_numbers_of_colors_are_a_friendly_error
    error = refusal_with(tiles: { town: :town_video, castle: :wide_video }, colors: { town: :town_colors, castle: :every_color })

    assert_match(/:castle/, error.message)
    assert_match(/colors/, error.message)
  end

  def test_cells_written_later_on_areas_of_the_pack_are_a_friendly_error
    word = PackBackgroundAreaGames.advance_word(2, 1, false, false)
    error = refusal_with(tiles: { town: :town_video, castle: :town_video }, set_cells: [word])

    assert_match(/set_cells:/, error.message)
    assert_match(/areas/, error.message)
  end
end
