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
  TURNS_AT = 0x200
  COPY_SIZE = 0x240
  # The pictures the town's tile 1 takes turns through, in a game that asks (`turning: true`).
  TURNS = [PLACES[2], PLACES[3]].freeze

  # Each area of the original: its tiles' places, its two banks of colours, and its map's cells, each
  # [tile, bank, mirrored, upside down], two to a row.
  Area = Data.define(:places, :banks, :cells, :map_at, :colors_at, :tiles_at)
  ACROSS = 2
  # Each area's map at a width of its own, as a room of an original is its own size: the town two
  # cells across and two down, the castle four across and one down.
  ACROSS_BY_AREA = { town: 2, castle: 4 }.freeze
  AREAS = {
    town: Area.new(places: PLACES, banks: BANKS,
                   cells: [[1, 0, false, false], [2, 1, true, false], [3, 0, false, false], [1, 1, false, true]],
                   map_at: TOWN_MAP_AT, colors_at: TOWN_COLORS_AT, tiles_at: TOWN_TILES_AT),
    castle: Area.new(places: [PLACES[0], PLACES[3], PLACES[1], PLACES[2]], banks: [OTHER, LATER],
                     cells: [[2, 1, false, false], [1, 0, false, true], [0, 0, false, false], [3, 1, true, true]],
                     map_at: CASTLE_MAP_AT, colors_at: CASTLE_COLORS_AT, tiles_at: CASTLE_TILES_AT)
  }.freeze
  # The same two areas drawn over ONE set of tiles: the castle's map read with the town's tiles and
  # colours, as `one_tile_slot: true` declares them.
  AREAS_OVER_ONE_SLOT = AREAS.transform_values { |area| area.with(places: PLACES, banks: BANKS) }.freeze
  # The cell each area may be written with later: [tile, bank, mirrored, upside down].
  WRITTEN = [3, 1, false, false].freeze
  # The pass the walk with a sprite (emit_walk_beside_sprite) walks to the castle.
  WALKS_ON = 4

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
    copy[TURNS_AT, 64] = TURNS.map(&LOW_HALF_FIRST).join
    path = File.join(folder, "made_up_areas.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game reading both areas from the pack, built as +options+ say. The block, run on the
  # builder, is the game loop, handed the background and, with +turning+, the group of pictures the
  # town's tile 1 takes turns through (nil without). Hands back the program and the pack file the
  # build made (nil for a build that leaves its pack out).
  #
  # With +one_tile_slot+ every area names the town's tiles and colours, and only its map is its own:
  # an original keeping two maps over one set of tiles in video memory. +across+ is one width for
  # every area's map, or a Hash of them by area. With +sized_maps+ each map carries its own width
  # (`as_map(across:)`, from +across+ by area) and the background is given no across: at all.
  private def areas_game_and_file(from, options: VBlank::Cartridge::Options.new, turning: false, set_cells: nil, one_tile_slot: false,
                                  across: ACROSS, sized_maps: false, &loop_body)
    told = set_cells ? { set_cells: set_cells } : {}
    told[:across] = across unless sized_maps
    width_of = ->(name) { across.is_a?(Hash) ? across.fetch(name) : across }
    art_of = ->(name) { one_tile_slot ? :town : name }
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        AREAS.each do |name, area|
          slots.tiles :"#{name}_video", at: area.tiles_at, count: area.places.length
          slots.numbers :"#{name}_map", at: area.map_at, count: area.cells.length, width: :half, signed: false
          slots.colors :"#{name}_colors", at: area.colors_at, count: 32
        end
        slots.tiles :turns, at: TURNS_AT, count: TURNS.length
      end
      groups = []
      groups << tile_pictures(:blocks, tiles: { pack[:town_video].tile(1) => pack[:turns].tiles(0, across: TURNS.length) }) if turning
      world = background :world, tiles: AREAS.keys.to_h { |name| [name, pack[:"#{art_of.(name)}_video"]] },
                                 map: AREAS.keys.to_h { |name|
                                   [name, sized_maps ? pack[:"#{name}_map"].as_map(across: width_of.(name)) : pack[:"#{name}_map"]]
                                 },
                                 colors: AREAS.keys.to_h { |name| [name, pack[:"#{art_of.(name)}_colors"]] }, **told
      instance_exec(world, groups.first, &loop_body)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE ANSWER KEY: both areas drawn by hand, walked by the same loop.
  private def areas_drawn_by_hand(areas = AREAS, across: ACROSS, &loop_body)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      maps = areas.to_h do |name, area|
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
        [name, drawn.each_slice(across.is_a?(Hash) ? across.fetch(name) : across).to_a]
      end
      world = background :world, tiles: areas.keys.to_h { |name| [name, :"#{name}_by_hand"] }, map: maps
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

  # A sprite stepping a pixel right on every pass over the background, which walks to the castle on
  # pass WALKS_ON and back to the town two passes later.
  def self.emit_walk_beside_sprite(builder, world)
    walks_on = WALKS_ON
    builder.instance_eval do
      image(:marker, "#" => :red) { (["#" * 8] * 8).join("\n") }
      hero = sprite :hero, at: [0, 0], facing: { still: :marker }
      tick = var :tick, 0
      game_loop do
        tick += 1
        hero.x += 1
        world.show_map :castle if tick == walks_on
        world.show_map :town if tick == walks_on + 2
      end
    end
  end

  # The town's tile 1 takes turns through two pictures of the pack (+blocks+): the second is chosen
  # on the second pass, the game walks to the castle on the fourth and back on the sixth.
  def self.emit_turning_walk(builder, world, blocks)
    builder.instance_eval do
      tick = var :tick, 0
      game_loop do
        tick += 1
        blocks.show 1 if tick == 2
        world.show_map :castle if tick == 4
        world.show_map :town if tick == 6
      end
    end
  end

  # A CELL WRITTEN LATER IN EACH AREA (WRITTEN): one cell number told for every area, each area
  # drawing it from its own tiles and colours. The town's top left is written on the second pass; the
  # game walks to the castle on the sixth and writes its bottom right on the eighth.
  def self.emit_written_cells(builder, world)
    word = advance_word(*WRITTEN)
    builder.instance_eval do
      tick = var :tick, 0
      game_loop do
        tick += 1
        world.set_cell 0, 0, word if tick == 2
        world.show_map :castle if tick == 6
        world.set_cell 1, 1, word if tick == 8
      end
    end
  end

  # A WORLD OF BIG ROOMS OVER ONE SLOT OF TILES: each room a map of its own, many cells each, every
  # one drawn from the town's four tiles and two banks, turned every way. A port draws a whole
  # world's rooms so, and the rooms share what they draw: the same few tiles as drawn, however many
  # cells and rooms there are.
  WORLD_ROOMS = %i[hall cellar loft].freeze
  WORLD_ACROSS = 40
  WORLD_DOWN = 24
  WORLD_MAPS_AT = 0x200

  # The cell +at+ of room number +room+: [tile, bank, mirrored, upside down].
  def self.world_cell(room, at) = [(at + (3 * room)) % 4, (at / 4) % 2, (at / 8).odd?, (at / 16).odd?]

  # The rooms named +rooms+, each +across+ by +down+ cells, as Areas over the town's tiles and colours.
  def self.world_areas(rooms, across, down)
    rooms.each_with_index.to_h do |name, room|
      cells = Array.new(across * down) { |at| world_cell(room, at) }
      [name, Area.new(places: PLACES, banks: BANKS, cells: cells, map_at: WORLD_MAPS_AT + (room * across * down * 2),
                      colors_at: TOWN_COLORS_AT, tiles_at: TOWN_TILES_AT)]
    end
  end

  # The made-up original holding the rooms of +areas+ (#world_areas).
  private def world_original(folder, areas)
    last = areas.values.last
    copy = "\0".b * (last.map_at + (last.cells.length * 2))
    copy[TOWN_COLORS_AT, 64] = BANKS.flatten.pack("v*")
    copy[TOWN_TILES_AT, 128] = PLACES.map(&LOW_HALF_FIRST).join
    areas.each_value do |area|
      copy[area.map_at, area.cells.length * 2] = area.cells.map { |cell| PackBackgroundAreaGames.advance_word(*cell) }.pack("v*")
    end
    path = File.join(folder, "made_up_world.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game walking the rooms of +areas+ (#world_areas), each map carrying its width, built as
  # +options+ say; the loop is #emit_world_walk. Hands back the program and the pack file made.
  private def world_game_and_file(folder, areas, across, options: VBlank::Cartridge::Options.new)
    from = world_original(folder, areas)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :town_video, at: TOWN_TILES_AT, count: PLACES.length
        slots.colors :town_colors, at: TOWN_COLORS_AT, count: 32
        areas.each { |name, area| slots.numbers :"#{name}_map", at: area.map_at, count: area.cells.length, width: :half, signed: false }
      end
      world = background :world, tiles: pack[:town_video], colors: pack[:town_colors],
                                 map: areas.keys.to_h { |name| [name, pack[:"#{name}_map"].as_map(across: across)] }
      PackBackgroundAreaGames.emit_world_walk(self, world, areas.keys)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # The first room on the first passes, and each next room two passes after the one before.
  def self.emit_world_walk(builder, world, rooms)
    builder.instance_eval do
      tick = var :tick, 0
      game_loop do
        tick += 1
        rooms.drop(1).each_with_index { |room, at| world.show_map room if tick == (2 * at) + 3 }
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

  # Two maps over one set of tiles in video memory: walking between them changes the map alone, and
  # the sprite moved on the pass of the walk shows where it was put on that frame, as on every other.
  def test_areas_over_one_tile_slot_walk_with_the_sprites_on_time
    by_hand = areas_drawn_by_hand(AREAS_OVER_ONE_SLOT) { |world| PackBackgroundAreaGames.emit_walk_beside_sprite(self, world) }
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), one_tile_slot: true) do |world|
        PackBackgroundAreaGames.emit_walk_beside_sprite(self, world)
      end

      ((WALKS_ON - 1)..(WALKS_ON + 4)).each do |frames|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), "frame #{frames}"
      end
      bottom_right = ->(frames) { game_player.run(walked, frames: frames).screen.then { |screen| (8...16).map { |x| screen.pixel(x, 12) } } }
      refute_equal bottom_right.(WALKS_ON - 1), bottom_right.(WALKS_ON + 1), "the castle's map shows"
    end
  end

  # The town's map two cells across and the castle's four, each area's own width.
  def test_each_area_map_shows_at_its_own_width
    by_hand = areas_drawn_by_hand(across: ACROSS_BY_AREA) { |world| PackBackgroundAreaGames.emit_walk(self, world) }
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), across: ACROSS_BY_AREA) do |world|
        PackBackgroundAreaGames.emit_walk(self, world)
      end

      { 2 => "the town, 2 cells across", 5 => "the castle, 4 cells across", 9 => "the town again" }.each do |frames, what|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), what
      end
    end
  end

  # Maps of two widths over one slot of tiles and one of colours are one set of tiles: the walk
  # changes the map alone.
  def test_areas_of_two_widths_over_one_tile_slot_walk_between_their_maps
    by_hand = areas_drawn_by_hand(AREAS_OVER_ONE_SLOT, across: ACROSS_BY_AREA) do |world|
      PackBackgroundAreaGames.emit_walk_beside_sprite(self, world)
    end
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), one_tile_slot: true, across: ACROSS_BY_AREA) do |world|
        PackBackgroundAreaGames.emit_walk_beside_sprite(self, world)
      end

      ((WALKS_ON - 1)..(WALKS_ON + 4)).each do |frames|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), "frame #{frames}"
      end
    end
  end

  # Each map carries its own width (`as_map(across:)`), and the background is given no across:.
  def test_each_area_map_that_carries_its_width_shows_at_that_width
    by_hand = areas_drawn_by_hand(across: ACROSS_BY_AREA) { |world| PackBackgroundAreaGames.emit_walk(self, world) }
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), across: ACROSS_BY_AREA, sized_maps: true) do |world|
        PackBackgroundAreaGames.emit_walk(self, world)
      end

      { 2 => "the town, 2 cells across", 5 => "the castle, 4 cells across", 9 => "the town again" }.each do |frames, what|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), what
      end
    end
  end

  # One background of the pack, its map carrying its width: the same picture as across: gives.
  def test_one_map_that_carries_its_width_needs_no_across
    Dir.mktmpdir do |folder|
      from = areas_original(folder)
      given = one_town_background(from, across: 2)
      sized = one_town_background(from, as_map: 2)

      assert_equal screen_at(given, 2), screen_at(sized, 2)
      refute_equal screen_at(one_town_background(from, across: 4), 2), screen_at(sized, 2), "the width is the map's"
    end
  end

  def test_a_map_that_carries_its_width_and_across_that_agree_build_alike
    Dir.mktmpdir do |folder|
      from = areas_original(folder)

      assert_equal screen_at(one_town_background(from, as_map: 2), 2), screen_at(one_town_background(from, as_map: 2, across: 2), 2)
    end
  end

  def test_a_map_width_given_two_ways_that_disagree_is_a_friendly_error
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { one_town_background(areas_original(folder), as_map: 2, across: 4) }

      assert_match(/across:/, error.message)
      assert_match(/2 cells across/, error.message)
    end
  end

  def test_area_map_widths_given_two_ways_that_disagree_are_a_friendly_error
    Dir.mktmpdir do |folder|
      from = areas_original(folder)
      error = assert_raises(ArgumentError) do
        b = VBlank::Builder.new
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :town_video, at: TOWN_TILES_AT, count: 4
            slots.numbers :town_map, at: TOWN_MAP_AT, count: 4, width: :half, signed: false
            slots.colors :town_colors, at: TOWN_COLORS_AT, count: 32
          end
          background :world, tiles: pack[:town_video], colors: pack[:town_colors], across: { town: 2, castle: 2 },
                             map: { town: pack[:town_map].as_map(across: 2), castle: pack[:town_map].as_map(across: 4) }
        end
      end

      assert_match(/:castle/, error.message)
      assert_match(/across:/, error.message)
    end
  end

  # The town alone, as one background of the pack: its map given +across+:, or carrying the width
  # +as_map+ (`as_map(across:)`), or both.
  private def one_town_background(from, across: nil, as_map: nil)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :town_video, at: TOWN_TILES_AT, count: 4
        slots.numbers :town_map, at: TOWN_MAP_AT, count: 4, width: :half, signed: false
        slots.colors :town_colors, at: TOWN_COLORS_AT, count: 32
      end
      map = as_map ? pack[:town_map].as_map(across: as_map) : pack[:town_map]
      background :town, tiles: pack[:town_video], map: map, colors: pack[:town_colors], **{ across: across }.compact
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Big rooms over one slot of tiles, each shown in turn: every cell as the same rooms drawn by hand.
  def test_a_world_of_big_rooms_over_one_tile_slot_shows_each_room
    areas = PackBackgroundAreaGames.world_areas(WORLD_ROOMS, WORLD_ACROSS, WORLD_DOWN)
    by_hand = areas_drawn_by_hand(areas, across: WORLD_ACROSS) { |world| PackBackgroundAreaGames.emit_world_walk(self, world, WORLD_ROOMS) }
    Dir.mktmpdir do |folder|
      walked, = world_game_and_file(folder, areas, WORLD_ACROSS)

      { 2 => "the hall", 4 => "the cellar", 6 => "the loft" }.each do |frames, what|
        assert_equal screen_at(by_hand, frames), screen_at(walked, frames), what
      end
    end
  end

  # With the pack left out, the build holds the tiles the rooms can draw, not a tile for every
  # cell: a world bigger than a background's tiles builds.
  def test_a_world_of_more_cells_than_a_background_holds_builds_with_the_pack_left_out
    rooms = %i[field forest lake marsh]
    areas = PackBackgroundAreaGames.world_areas(rooms, 126, 86)
    left_out = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
    Dir.mktmpdir do |folder|
      program, = world_game_and_file(folder, areas, 126, options: left_out)

      assert(program.walk.any? { |node| node.kind == :background && node.from_file })
    end
  end

  def test_across_by_area_naming_other_areas_is_a_friendly_error
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        areas_game_and_file(areas_original(folder), across: { town: 2, keep: 4 }) { |world| PackBackgroundAreaGames.emit_walk(self, world) }
      end

      assert_match(/across:/, error.message)
      assert_match(/the same areas/, error.message)
    end
  end

  def test_the_two_areas_show_different_pictures
    by_hand = areas_drawn_by_hand { |world| PackBackgroundAreaGames.emit_walk(self, world) }

    refute_equal screen_at(by_hand, 2), screen_at(by_hand, 5)
  end

  # The town's tile 1 takes turns through two pictures of the pack: the second is chosen on the
  # second pass, the game walks to the castle and back, and the town shows the second still.
  def test_a_tile_taking_turns_in_one_area_keeps_its_picture_through_a_walk
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), turning: true) do |world, blocks|
        PackBackgroundAreaGames.emit_turning_walk(self, world, blocks)
      end
      first = game_player.run(walked, frames: 1).screen.pixel(1, 0)
      second = game_player.run(walked, frames: 3).screen.pixel(1, 0)

      refute_equal first, second, "the second picture shows in the town"
      assert_equal second, game_player.run(walked, frames: 9).screen.pixel(1, 0), "and again after the walk"
    end
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

  private def areas_with_written(written)
    AREAS.to_h { |name, area| [name, area.with(cells: area.cells.each_with_index.map { |cell, at| at == written[name] ? WRITTEN : cell })] }
  end

  def test_a_cell_written_later_shows_the_tile_of_the_area_showing
    word = PackBackgroundAreaGames.advance_word(*WRITTEN)
    Dir.mktmpdir do |folder|
      walked, = areas_game_and_file(areas_original(folder), set_cells: [word]) do |world|
        PackBackgroundAreaGames.emit_written_cells(self, world)
      end
      town = areas_drawn_by_hand(areas_with_written(town: 0)) { |world| PackBackgroundAreaGames.emit_walk(self, world) }
      castle = areas_drawn_by_hand(areas_with_written(castle: 3)) { |world| PackBackgroundAreaGames.emit_walk(self, world) }

      assert_equal screen_at(town, 2), screen_at(walked, 4), "the town, its top left written"
      assert_equal screen_at(castle, 5), screen_at(walked, 11), "the castle, its bottom right written"
    end
  end

  def test_a_cell_no_area_was_told_is_a_friendly_error
    told = PackBackgroundAreaGames.advance_word(*WRITTEN)
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        areas_game_and_file(areas_original(folder), set_cells: [told]) do |world|
          world.set_cell 0, 0, told + 1
          game_loop { wait_vblank }
        end
      end

      assert_match(/set_cells:/, error.message)
    end
  end

  def test_set_cells_other_than_cell_numbers_on_areas_of_the_pack_are_a_friendly_error
    error = refusal_with(tiles: { town: :town_video, castle: :town_video }, set_cells: :town_map)

    assert_match(/set_cells:/, error.message)
    assert_match(/areas/, error.message)
  end
end
