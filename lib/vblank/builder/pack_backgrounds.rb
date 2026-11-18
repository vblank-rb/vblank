# frozen_string_literal: true

module VBlank
  class Builder
    # A BACKGROUND DRAWN FROM THE ORIGINAL'S OWN PICTURES, MAP AND COLOURS, read from the data pack.
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.tiles   :title_video,  count: 2048, colors: 16
    #     slots.numbers :city_map,     count: 512, width: :half, signed: false
    #     slots.colors  :title_colors, count: 128
    #   end
    #   background :city, tiles: pack[:title_video], map: pack[:city_map], colors: pack[:title_colors],
    #                     across: 32, cell: 16
    #
    # A retail game decides nothing about a cell of a screen: it copies the screen's tiles into video
    # memory, its map into the console's map and its colours into colour memory, and the console
    # draws each cell from its number. So the background is given the same three, as the original
    # keeps them, all but the map: each cell of it is a record of VBlank's own (Original::MapCell:
    # which tile, which bank of colours, mirrored or upside down), which the port's unpacking writes
    # from the original's maps, so nothing here knows how any one console keeps a cell:
    #
    #   slots.map_cells :city_map, count: 1024    # written by `pack[:city_map].write_cell(at, tile:, ...)`
    #
    # A SHORTCUT FOR A CONSOLE VBLANK KNOWS: a map of numbers of two bytes is read as the original's
    # console keeps a cell (Console::OriginalFormats#map_words, the Advance's, the Super Nintendo's
    # and the Genesis's), as `slots.numbers :city_map, ..., width: :half` in the example at the top
    # is. Both are read by one reader
    # (Console::MapWordFormat), the record being a layout like any console's.
    #
    # A MAP OF ONE BYTE A CELL OVER TILES OF A BYTE A PIXEL is the other way a console keeps a
    # background: the layer it turns and resizes (the Advance's turning layer, the Super
    # Nintendo's Mode 7). The console reads such a layer a pixel at a time, working back from the
    # screen through the turn, so a cell is a tile's number and nothing else (Console::
    # BYTE_MAP_CELLS) and a pixel is a whole byte, a place in one table of 256 colours
    # (Console::BYTE_A_PIXEL_TILES). The same three are given, as those:
    #
    #   slots.tiles   :sword_pictures, count: 256, colors: 256
    #   slots.numbers :sword_map,      count: 1024, width: :byte, signed: false
    #   sword = background :sword, tiles: pack[:sword_pictures], map: pack[:sword_map],
    #                              colors: pack[:title_colors], across: 32
    #   sword.turns_around(120, 72, map_point: [128, 128]).scale(16.0)
    #
    # What is declared is a background like any other, so it turns as one the game draws itself
    # does. Its tiles pick from the whole table and not from a bank, so there is no list of
    # colours to name (#drawn_from_whole_table?).
    #
    # The same tiles under map cells, or under a console's own cells of two bytes, are a layer of
    # 256 colours that scrolls, as the Advance keeps a text layer of 256 colours: each cell names
    # its tile and its turns, and its bank is not read (#cell_format_without_banks).
    #
    # THE COLOURS ARE NAMED LISTS, a bank each. Bank +n+ of the slot is the list `:<slot>_<n>`
    # (`:title_colors_0`), so a game fades the background or draws it with other colours by those
    # names, as it would a background of its own (`city.draw_with color_walk(:title_colors_0, from:
    # :black), showing: step`). Two backgrounds from one slot share its lists. `draw_with` takes any
    # bank of the slot, and one this background's map does not use changes nothing: which banks a
    # map uses is in the player's copy, so a game names every bank its screen fades.
    #
    # BUILT ALL-IN-ONE, the cells are worked out here from what the slots hold, as a port would
    # have worked them out by hand: each different tile as drawn (a tile, its bank and its turn) a
    # picture of 8x8, and the map those pictures, a big cell its tiles. So the console, the
    # interpreter and every build draw it as any background, and a tile that draws nothing is
    # left empty. On a console that draws tiles of 16x16, a cell of 16x16 is one picture of that
    # size instead, as the original's map is (#big_pack_cells?).
    #
    # WITH THE PACK LEFT OUT nothing of the slots is known here: not which tiles the map names, nor
    # which bank each is drawn from, nor one colour. So the background is declared by where its
    # map, tiles and colours are in the file the program is handed as it starts
    # (IR::StartFile::Background), and each backend that plays such a program works the cells out
    # as it starts, as they are worked out here. What the build must still know is true of it: its
    # size, and the names of its lists, every bank of the slot, since any of them may be drawn
    # from. A bank's colours are not known, so its list holds a marker for each
    # (#declare_bank_stand_in), and what a build holding them works out from them, the steps of a
    # `color_walk` among it, is made as the game starts. The cells the game may write later
    # (`set_cells:`) are the one thing of the picture known here, all but their pixels, so each
    # of their tiles is a picture read from the file (#declare_told_tile_read_at_start).
    module PackBackgrounds
      private

      # The background +name+ from +tiles+, +map+ and +colors+ (DSL::PackSlot handles), +across+
      # cells to a row of the map, each cell +cell+ pixels square. +others+ are the background's
      # own settings, handed on.
      def declare_pack_background(name, tiles:, map:, colors:, across:, cell:, set_cells: nil, cells_in_front: nil, **others)
        map, across = pack_map_slot_and_across!(name, map, across)
        subject = "background :#{name}"
        refuse_tiles_not_from_slot!(tiles, subject)
        refuse_map_not_of_cells!(name, map)
        refuse_colors_not_whole_slot!(name, colors)
        words = pack_map_word_format!(name, map)
        words = cell_format_without_banks(words) if drawn_from_whole_table?(tiles)
        words = front_read_format!(name, words) if refuse_bad_cells_in_front!(name, cells_in_front)
        refuse_colors_short_of_table!(name, tiles, colors)
        refuse_bad_pack_background_shape!(name, map, across, cell, words)
        refuse_set_cells_of_table_tiles!(name, tiles, set_cells)
        told_slot = (refuse_bad_told_slot!(name, set_cells, words) if set_cells.is_a?(DSL::PackSlot))
        tiles_a_side = cell / Original::Slot::TILE_SIDE
        record_pack_background_slot(tiles)
        moving = moving_pack_tiles_of(tiles)
        refuse_moving_table_tiles!(name, tiles) unless moving.empty?
        if pack_left_out?
          return declare_pack_background_read_at_start(name, tiles: tiles, map: map, colors: colors, across: across,
                                                             tiles_a_side: tiles_a_side, words: words, set_cells: set_cells,
                                                             moving: moving, **others)
        end

        # A slot's cells are known here: they are the told cells, written by their place in it.
        set_cells = pack_slot_values(told_slot, :map_cells, "background :#{name}'s set_cells:") if told_slot

        tile_places = pack_tile_places(tiles, subject)
        bank_lists = if drawn_from_whole_table?(tiles)
                       pack_color_tables(colors, tiles.layout.format.colors, "#{subject}'s colors:")
                     else
                       declare_pack_color_banks(colors, tiles.layout.format.colors, "#{subject}'s colors:")
                     end
        map_cells = pack_map_cells(map, "#{subject}'s map:")
        refuse_banks_over_table_tiles!(name, tiles, map, map_cells)
        map_words = map_cells.each_slice(across).to_a
        shape = PackMapShape.new(name: name, words: words, tiles_a_side: tiles_a_side, tile_places: tile_places,
                                 bank_lists: bank_lists)
        # A picture of 16x16 is drawn from a bank's list, and tiles of 256 colours have none, so
        # those keep 8x8 tiles.
        big = big_pack_cells?(tiles_a_side) && !drawn_from_whole_table?(tiles)
        turning = (turning_big_cells(shape, map_words, set_cells, moving) if big)
        made = if turning && big_cells_turn_in_one_group?(turning, moving)
                 pack_background_of_big_cells(shape, map_words, set_cells, turning, moving)
               else
                 pack_background_of_tiles(shape, map_words, set_cells, moving)
               end
        drawn = made.pictures.values.compact
        refuse_pack_background_drawing_nothing!(name) if drawn.empty?
        tileset = :"background :#{name} tiles"
        tiles(tileset, drawn.to_h { |picture| [picture, picture] })
        # Which banks the map uses is in the player's copy, so the game may name any bank of the slot.
        # Tiles drawn from the whole table have no list, so there is none to name.
        named = drawn_from_whole_table?(tiles) ? [] : bank_lists
        told = told_slot ? made.told.by_place(set_cells.map { |word| made.told.tiles_of(word) }) : made.told
        handle = background(name, tiles: tileset, map: made.rows, **others).allow_undrawn_lists(named).allow_set_cells(told)
        mark_tiles_in_front(name, made.pictures) if words.reads_front
        handle
      end

      # A BACKGROUND OF THE PACK THAT WALKS BETWEEN AREAS. A port keeps each level's art as slots of
      # one shape: its video image, its map, its lists of colours. So `tiles:`, `map:` and `colors:`
      # can each be a Hash of slots by area, or one slot every area shares:
      #
      #   background :arena, tiles: { town: pack[:town_video], castle: pack[:castle_video] },
      #                      map: { town: pack[:town_map], castle: pack[:castle_map] },
      #                      colors: { town: pack[:town_colors], castle: pack[:castle_colors] }, across: 32
      #   arena.show_map :castle
      #
      # Each area is made as a background of the pack is built all-in-one (#pack_areas_art), and the
      # areas become one background walking between tilesets (Builder::Tiled#background_from_sets),
      # each area's map named for its area. So every console that walks a background between areas
      # walks this one, and `show_map` takes the area's name or its number. Areas over one slot of
      # tiles are one tileset, and walking between them changes only the map.
      #
      # EACH AREA'S MAP CAN BE A WIDTH OF ITS OWN. A room of an original is a map of the room's own
      # size, so `across:` can be a Hash by area too, as the slots are:
      #
      #   background :rooms, tiles: pack[:house_video], map: { hall: pack[:hall_map], field: pack[:field_map] },
      #                      colors: pack[:house_colors], across: { hall: 30, field: 126 }
      #
      # The maps are then of different sizes, which a background keeps whole and brings into view a
      # strip at a time (IR::TileMap.streams?), as it does a game's own maps of different sizes.
      #
      # A MAP CAN CARRY ITS OWN WIDTH instead (DSL::PackSlot#as_map), so the width goes with the map
      # and the background needs no across: at all:
      #
      #   background :rooms, tiles: pack[:house_video], colors: pack[:house_colors],
      #                      map: { hall: pack[:hall_map].as_map(across: 30), field: pack[:field_map].as_map(across: 126) }
      #
      # across: by area stays, as a shorthand that builds the same bytes: games written with it need
      # not change. A width given both ways must agree (#pack_map_slot_and_across!).
      def pack_areas?(tiles, map, colors)
        [tiles, map, colors].any? { |given| given.is_a?(Hash) && given.each_value.any? { |value| pack_map_handle?(value) } }
      end

      # Is +given+ a handle on a slot of the pack, or a map of one that carries its width?
      def pack_map_handle?(given) = given.is_a?(DSL::PackSlot) || given.is_a?(DSL::PackMap)

      def declare_pack_background_areas(name, tiles:, map:, colors:, across:, cell:, set_cells: nil, cells_in_front: nil, **others)
        areas = pack_area_names!(name, tiles: tiles, map: map, colors: colors, across: across)
        refuse_written_cells_on_areas!(name, set_cells, cells_in_front)
        slots = areas.to_h do |area|
          map_slot, map_across = pack_map_slot_and_across!(:"#{name}'s area :#{area}", setting_of_area(map, area),
                                                           setting_of_area(across, area))
          [area, { tiles: setting_of_area(tiles, area), map: map_slot, colors: setting_of_area(colors, area), across: map_across }]
        end
        refuse_areas_of_two_shapes!(name, slots)
        return declare_pack_areas_read_at_start(name, slots, cell: cell, set_cells: set_cells, **others) if pack_left_out?

        told = slots.keys.to_h { |area| [area, set_cells.is_a?(Hash) ? set_cells[area] : set_cells] }
        # Areas over one slot of tiles in one slot of colours, told the same cells, are made
        # together as one tileset, so they are one set to walk between (Builder::Tiled#background_from_sets).
        groups = slots.keys.group_by { |area| [slots[area][:tiles], slots[area][:colors], told[area]] }
        art = groups.each_value.reduce({}) do |made, areas|
          made.merge(pack_areas_art(name, areas.to_h { |area| [area, slots[area][:map]] },
                                    across: areas.to_h { |area| [area, slots[area][:across]] }, cell: cell,
                                    set_cells: told[areas.first], tiles: slots[areas.first][:tiles],
                                    colors: slots[areas.first][:colors]))
        end
        art = slots.keys.to_h { |area| [area, art.fetch(area)] }
        handle = background(name, tiles: art.transform_values(&:tileset), map: art.transform_values(&:rows), **others)
        handle.allow_undrawn_lists(art.values.flat_map(&:lists).uniq)
        return handle if set_cells.nil?

        # Each area's pictures are named for it, so a picture is one tile of the background however
        # many areas tell the same cell number.
        handle.allow_set_cells_by_area(art.values.map(&:told), @backgrounds.fetch(name).node.tiles)
      end

      # One area's art: the name of its tileset, its map's rows of pictures, the lists of colours
      # the game may name for it, and the cells `set_cell` may write in it (a DSL::PackCells, or nil).
      PackAreaArt = Data.define(:tileset, :rows, :lists, :told)

      # What the setting +given+ (a slot, or across:'s width) names for +area+: its own in a Hash by
      # area, or the one every area shares.
      def setting_of_area(given, area) = given.is_a?(Hash) ? given.fetch(area) : given

      # The map's slot and its width, from +map+ (a slot, or a DSL::PackMap carrying its width) and
      # +across+. A map that carries its width needs no across:; given both, they must agree.
      def pack_map_slot_and_across!(name, map, across)
        return [map, across] unless map.is_a?(DSL::PackMap)
        return [map.slot, map.across] if across.nil? || across == map.across

        raise ArgumentError, "background :#{name} was given a map #{map.across} cells across, and across: " \
                             "#{Messages::PlainWords.words_for_given(across)}. To fix this, leave across: out, since " \
                             "the map carries its width."
      end

      # The areas of a background of the pack, from whichever of +given+ (tiles:, map:, colors:,
      # across:) are a Hash by area: each must name the same areas in the same order, since the
      # maps are counted in that order.
      def pack_area_names!(name, **given)
        named = given.select { |_, value| value.is_a?(Hash) }
        (setting, areas), *others = named.map { |key, value| [key, value.keys] }
        other, differing = others.find { |_, keys| keys != areas }
        return areas unless other

        raise ArgumentError, "background :#{name} names the areas #{areas.map(&:inspect).join(', ')} in #{setting}: and the " \
                             "areas #{differing.map(&:inspect).join(', ')} in #{other}:. Each Hash by area must " \
                             "name the same areas, in the same order."
      end

      # The cells written later are told as numbers (a list or a range), for every area or a Hash of
      # them by area; a slot of told cells, and cells in front of the sprites, are not made for areas.
      def refuse_written_cells_on_areas!(name, set_cells, cells_in_front)
        given = { set_cells: (set_cells unless [NilClass, Array, Range, Hash].include?(set_cells.class)),
                  cells_in_front: (cells_in_front if cells_in_front) }.compact.keys
        return if given.empty?

        raise ArgumentError, "background :#{name} walks between areas of the data pack, and was given " \
                             "#{given.map { |key| "#{key}:" }.join(' and ')}. VBlank does not make that yet for areas. " \
                             "To fix this, give set_cells: the cell numbers, or give each look of a room a map of its " \
                             "own and use show_map."
      end

      # All the areas of one background are drawn alike: their maps keep a cell the same way, and
      # their tiles have the same number of colours. Each area is checked for what each slot must be
      # first, so the words name the area.
      def refuse_areas_of_two_shapes!(name, slots)
        shapes = slots.to_h do |area, given|
          subject = "background :#{name}'s area :#{area}"
          refuse_tiles_not_from_slot!(given[:tiles], subject)
          refuse_map_not_of_cells!(:"#{name}'s area :#{area}", given[:map])
          refuse_colors_not_whole_slot!(:"#{name}'s area :#{area}", given[:colors])
          [area, [pack_map_word_format!(name, given[:map]), given[:tiles].layout.format.colors]]
        end
        (first, (words, colors)), *rest = shapes.to_a
        rest.each do |area, (other_words, other_colors)|
          if other_words != words
            raise ArgumentError, "background :#{name} reads the map of the area :#{area} in another layout than the map of " \
                                 "the area :#{first}. Each cell of the two maps is kept another way. All the areas of " \
                                 "one background must keep a cell the same way. To fix this, give every area a map slot " \
                                 "of one kind."
          end
          next if other_colors == colors

          raise ArgumentError, "background :#{name} has tiles of #{other_colors} colors in the area :#{area}, and tiles of " \
                               "#{colors} colors in the area :#{first}. All the areas of one background must have tiles " \
                               "of the same number of colors."
        end
      end

      # The area +own+ (a background's name and the area's) checked as #declare_pack_background
      # checks a background of one area, and its slot of tiles recorded. Hands back how a cell of
      # its map is read (a Console::MapWordFormat) and its tiles that take turns through pictures.
      def refuse_bad_pack_area!(own, tiles:, map:, colors:, across:, cell:, set_cells:)
        words = pack_map_word_format!(own, map)
        words = cell_format_without_banks(words) if drawn_from_whole_table?(tiles)
        refuse_colors_short_of_table!(own, tiles, colors)
        refuse_bad_pack_background_shape!(own, map, across, cell, words)
        refuse_set_cells_of_table_tiles!(own, tiles, set_cells)
        record_pack_background_slot(tiles)
        moving = moving_pack_tiles_of(tiles)
        refuse_moving_table_tiles!(own, tiles) unless moving.empty?
        [words, moving]
      end

      # THE ART OF AREAS OVER ONE SLOT OF TILES, made as #declare_pack_background makes a background
      # built all-in-one, from each area's map of +maps+ (a slot by area). The pictures are named for
      # the areas, so the pictures of areas over other slots never meet. Areas over one slot, in one
      # slot of colours, draw the same pictures, so they are made once, from every area's map at once,
      # as one tileset: an original keeping several maps over one stretch of tiles in video memory
      # changes the map alone, and so does the walk between them. Hands back a PackAreaArt by area.
      #
      # +across+ is each area's width, by area. +set_cells+ are the cells `set_cell` may write in
      # these areas, made pictures of their own.
      def pack_areas_art(name, maps, tiles:, colors:, across:, cell:, set_cells: nil)
        own = if maps.one?
                :"#{name}'s area :#{maps.keys.first}"
              else
                :"#{name}'s areas #{maps.keys.map(&:inspect).join(', ')}"
              end
        subject = "background :#{own}"
        words, moving = maps.map do |area, map|
          refuse_bad_pack_area!(maps.one? ? own : :"#{name}'s area :#{area}", tiles: tiles, map: map, colors: colors,
                                                                               across: across.fetch(area), cell: cell, set_cells: set_cells)
        end.first
        tile_places = pack_tile_places(tiles, subject)
        bank_lists = if drawn_from_whole_table?(tiles)
                       pack_color_tables(colors, tiles.layout.format.colors, "#{subject}'s colors:")
                     else
                       declare_pack_color_banks(colors, tiles.layout.format.colors, "#{subject}'s colors:")
                     end
        rows_by_area = maps.to_h do |area, map|
          map_cells = pack_map_cells(map, "background :#{name}'s area :#{area}'s map:")
          refuse_banks_over_table_tiles!(:"#{name}'s area :#{area}", tiles, map, map_cells)
          [area, map_cells.each_slice(across.fetch(area)).to_a]
        end
        shape = PackMapShape.new(name: own, words: words, tiles_a_side: cell / Original::Slot::TILE_SIDE, tile_places: tile_places,
                                 bank_lists: bank_lists)
        rows = rows_by_area.values.flatten(1)
        # A tile taking turns through pictures (PackTilePictures) is a tile of a run, made for the
        # area as for a background of one area: each area showing the group has runs of its own,
        # and the group's `show` copies into every run.
        big = big_pack_cells?(shape.tiles_a_side) && !drawn_from_whole_table?(tiles)
        turning = (turning_big_cells(shape, rows, set_cells, moving) if big)
        made = if turning && big_cells_turn_in_one_group?(turning, moving)
                 pack_background_of_big_cells(shape, rows, set_cells, turning, moving)
               else
                 pack_background_of_tiles(shape, rows, set_cells, moving)
               end
        drawn = made.pictures.values.compact
        refuse_pack_background_drawing_nothing!(own) if drawn.empty?
        tileset = :"background :#{own} tiles"
        tiles(tileset, drawn.to_h { |picture| [picture, picture] })
        # Each row of a map is made one row of pictures or several, the same number for every row.
        per_row = made.rows.length / rows.length
        first = 0
        rows_by_area.transform_values do |area_rows|
          area_made = made.rows[first * per_row, area_rows.length * per_row]
          first += area_rows.length
          PackAreaArt.new(tileset: tileset, rows: area_made, lists: drawn_from_whole_table?(tiles) ? [] : bank_lists, told: made.told)
        end
      end

      # CELLS IN FRONT OF THE SPRITES (`cells_in_front: true`). A console that keeps a priority bit
      # in each cell of its map (the Genesis, the Super Nintendo) draws a cell with it set over the
      # sprites, and a retail game sets it on the scenery a character walks behind: the machine in
      # the middle of a room, the top of a doorway. A cell's mark is read with the rest of it
      # (Console::MapWordFormat#in_front?), so each tile as drawn that is in front is a picture of
      # its own beside the same tile behind, and the background is told which of its tiles those
      # are (Nodes::Background#in_front). Being the tile's, the mark goes wherever the tile does: a
      # cell `set_cell` writes takes its own. A tile that is in front and behind is held twice;
      # a console that keeps each 8x8 square once (the Genesis) holds the square once all the same.
      #
      # ONLY A BACKGROUND THAT ASKS READS THE MARK. A port that copies the original's map whole
      # copies a priority bit on every cell, and a game written before the mark was read draws
      # those cells behind, so it builds the same as it always did.
      def refuse_bad_cells_in_front!(name, cells_in_front)
        return cells_in_front if [true, false, nil].include?(cells_in_front)

        raise ArgumentError, "background :#{name} was given cells_in_front: #{cells_in_front.inspect}. It takes true, " \
                             "to draw each cell its map marks in front of the sprites, or false."
      end

      # +words+ reading each cell's mark for being in front, where the layout keeps one.
      def front_read_format!(name, words)
        return words.with_front_read if words.front_bit

        raise ArgumentError, "background :#{name} was given cells_in_front: true, and its map holds no mark for a cell " \
                             "in front of the sprites. A cell of the Advance's own map, or a map of one byte a cell, " \
                             "keeps no such mark. To fix this, give map: a slot of map cells, and write each cell with " \
                             "`write_cell(at, tile:, in_front: true)` in the unpacking. Or put the whole background in " \
                             "front of the sprites with `layers`."
      end

      # Tells the background +name+ which of its tiles are in front of the sprites: the pictures
      # among +pictures+ (by what each was made from, nil for one that draws nothing) of a tile as
      # drawn in front, or of a 16x16 cell whose quarters are.
      def mark_tiles_in_front(name, pictures)
        front = pictures.filter_map { |made_from, picture| picture if picture && pack_tile_in_front?(made_from) }
        node = @backgrounds.fetch(name).node
        node.in_front = node.tiles.each_index.select { |at| front.include?(node.tiles[at]) }
      end

      # Is +made_from+ (a Console::CellTile, the quarters of a 16x16 cell, or a key of a blank told
      # tile) a tile in front of the sprites?
      def pack_tile_in_front?(made_from)
        case made_from
        when Console::CellTile then made_from.in_front
        when Array then made_from.first.is_a?(Console::CellTile) && made_from.first.in_front
        else false
        end
      end

      # `set_cells: pack[:changes]`: A SLOT OF MAP CELLS TELLS THE CELLS THE BACKGROUND MAY BE
      # WRITTEN LATER, as a port's unpacking works out every cell its screen changes to, and
      # `set_cell` names one by its place in the slot. Its cells are records (Original::MapCell),
      # so the map is map cells too, a cell of 8x8 pixels. Hands back the slot.
      def refuse_bad_told_slot!(name, slot, words)
        refuse_slot_from_elsewhere!(slot, "background :#{name}'s set_cells:")
        unless slot.shape == :map_cells && !slot.one_tile? && !slot.run_of_numbers?
          raise ArgumentError, "background :#{name} was given set_cells: slot :#{slot.layout.name}, which holds " \
                               "#{slot.shape}. To tell the cells set_cell can write from the pack, give a slot of map " \
                               "cells, like `slots.map_cells :changes, count: 216`."
        end
        return slot if words.without_front_read == Original::MapCell::FORMAT

        raise ArgumentError, "background :#{name} was given set_cells: slot :#{slot.layout.name}, a slot of map cells, " \
                             "and its map: holds numbers in the layout of the original's console. Only a map of map " \
                             "cells takes told cells from a slot. To fix this, give map: a slot of map cells, or give " \
                             "set_cells: the cell numbers."
      end

      # What making a background's pictures from the pack reads: the background's +name+, the layout
      # of a cell (+words+, Console::MapWordFormat), how many tiles a cell is across, each tile's
      # places from the slot, and the bank lists by bank.
      PackMapShape = Data.define(:name, :words, :tiles_a_side, :tile_places, :bank_lists)

      # What making them gives back: the map's +rows+ of picture names, every +pictures+ made (nil
      # for what draws nothing) by what it was made from, and the cells `set_cell` may write
      # (+told+, a DSL::PackCells, or nil).
      PackMapPictures = Data.define(:rows, :pictures, :told)

      # A CELL OF 16x16 IS ONE TILE OF 16x16 where the console draws such tiles. A Super Nintendo
      # original keeps such a screen as a map of 32 by 32 cells, and its own game shows it as a layer
      # of 16x16 tiles: a map of 2 KB, which goes to video memory in the blank as the screen comes in.
      # Made of 8x8 pictures the same screen is a map of 64 by 64, four times the bytes, and sending
      # it holds the game for frames as the scene arrives. So where the console has tiles of 16x16
      # each different cell as drawn is one picture of 16x16, as a game drawing the screen itself
      # would declare it, and writing a cell (set_cell) is one word of the map, not four. A cell
      # with a quarter that takes turns through pictures is a 16x16 picture of a run
      # (PackTilePictures#declare_moving_pack_big_cells). A program built for no console (a
      # test's) is laid out for none, so it keeps 8x8 tiles.
      def big_pack_cells?(tiles_a_side)
        tiles_a_side == 2 && !@program.console.nil? && @console.big_background_tiles
      end

      # The quarters (#pack_cell_quarters) of every different cell the map's +map_words+ and
      # +set_cells+ name that has a quarter among +moving+.
      def turning_big_cells(shape, map_words, set_cells, moving)
        return [] if moving.empty?

        side = shape.tiles_a_side
        cells = map_words.flatten.map { |word| pack_cell_quarters(shape.words, word) } +
                told_cell_tiles(shape.name, set_cells, shape.words, side).each_slice(side * side).to_a
        cells.uniq.select { |quarters| quarters.any? { |tile| moving.key?(tile.tile) } }
      end

      # Whether each of +turning+ (#turning_big_cells) has its quarters that take turns in one group:
      # a run is one group's, so a cell whose quarters take turns in two groups cannot be one picture
      # of a run, and the background keeps 8x8 tiles.
      def big_cells_turn_in_one_group?(turning, moving)
        turning.all? do |quarters|
          groups = quarters.filter_map { |tile| moving[tile.tile]&.first }
          groups.uniq.one?
        end
      end

      # The map of +map_words+ (rows of cells) as a picture of 16x16 for each cell, kept by its
      # cell's four tiles; a cell of +turning+ (#turning_big_cells) is a picture of a run. Hands back
      # a PackMapPictures.
      def pack_background_of_big_cells(shape, map_words, set_cells, turning, moving)
        pictures = declare_moving_pack_big_cells(shape, turning, moving)
        rows = map_words.map do |row|
          row.map do |word|
            quarters = pack_cell_quarters(shape.words, word)
            pictures.fetch(quarters) { pictures[quarters] = pack_background_big_cell(shape, quarters, pictures.length) }
          end
        end
        told = declare_pack_cells_written_later(shape.name, set_cells, shape.words, shape.tiles_a_side, pictures,
                                                shape.bank_lists, big: true) do |quarters, number|
          pack_background_big_cell(shape, quarters, number)
        end
        PackMapPictures.new(rows: rows, pictures: pictures, told: told)
      end

      # The map of +map_words+ (rows of cells) as a picture of 8x8 for each tile as drawn, a cell
      # +shape.tiles_a_side+ of them each way. Hands back a PackMapPictures.
      def pack_background_of_tiles(shape, map_words, set_cells, moving)
        side = shape.tiles_a_side
        cells = map_words.flat_map do |row|
          Array.new(side) do |down|
            row.flat_map { |word| Array.new(side) { |along| shape.words.cell_tile(word, along, down, side) } }
          end
        end
        # The tiles that take turns through pictures are tiles of runs (PackTilePictures): the map's,
        # then those of the cells set_cell may write, in banks and turns the map may never name.
        drawn = [*cells.flatten, *told_cell_tiles(shape.name, set_cells, shape.words, side)].uniq
        pictures = declare_moving_pack_tiles(shape.name, drawn.select { |tile| moving.key?(tile.tile) }, moving, shape.bank_lists)
        rows = cells.map do |row|
          row.map do |tile|
            pictures.fetch(tile) do
              pictures[tile] = pack_background_tile(shape.name, tile, shape.tile_places, shape.bank_lists, pictures.length)
            end
          end
        end
        told = declare_pack_cells_written_later(shape.name, set_cells, shape.words, side, pictures, shape.bank_lists) do |tile, number|
          pack_background_tile(shape.name, tile, shape.tile_places, shape.bank_lists, number)
        end
        PackMapPictures.new(rows: rows, pictures: pictures, told: told)
      end

      # Every tile as drawn (a Console::CellTile) of the cells +set_cells+ names, +side+ tiles each
      # way of a cell; none where it names none.
      def told_cell_tiles(name, set_cells, words, side)
        return [] if set_cells.nil?

        cells = DSL::PackCells.new(format: words, side: side, tiles_by_word: {})
        pack_cell_words!(name, set_cells, cells).flat_map { |word| pack_cell_tiles(words, word, side) }
      end

      # The tiles of the cell +word+, +side+ each way, as drawn, row by row.
      def pack_cell_tiles(words, word, side) = Array.new(side * side) { |at| words.cell_tile(word, at % side, at / side, side) }

      # The four tiles of the 16x16 cell +word+, as drawn: top left, top right, bottom left, bottom right.
      def pack_cell_quarters(words, word) = pack_cell_tiles(words, word, 2).freeze

      # The picture of 16x16 of a cell whose tiles as drawn are +quarters+ (#pack_cell_quarters),
      # drawn from the list of its bank. Nil for a cell that draws nothing, left empty in the map.
      def pack_background_big_cell(shape, quarters, number)
        side = Original::Slot::TILE_SIDE
        turned = quarters.map do |tile|
          places = pack_tile_at(shape.tile_places, tile.tile, "background :#{shape.name}")
          turned_rows(places.each_slice(side).to_a, mirrored: tile.mirrored, upside_down: tile.upside_down)
        end
        return nil if turned.flatten.all?(&:zero?)

        places = Array.new(2 * side) do |y|
          Array.new(2 * side) { |x| turned[((y / side) * 2) + (x / side)][y % side][x % side] }
        end.flatten
        picture = :"background :#{shape.name} cell #{number}"
        define_pack_bank_tile(picture, places, pack_bank_list(shape.name, quarters.first.bank, shape.bank_lists), side: 2 * side)
        picture
      end

      # TILES OF MORE COLOURS THAN A LIST HOLDS ARE DRAWN FROM THE WHOLE TABLE. A tile of sixteen
      # colours picks from a bank, which is a list the game can name, walk and swap. A tile kept
      # a byte a pixel (Console::BYTE_A_PIXEL_TILES) picks from all 256 colours at once, as the
      # layer a console turns and resizes does, and no list is that long. So its pictures hold
      # their colours themselves, as a picture the game draws from colours does, and the
      # background has no list to draw with others.
      def drawn_from_whole_table?(tiles) = tiles.layout.format.colors > Images::PICTURE_COLORS

      # The cells of +map+ (a slot of numbers, or a run of one), in order.
      def pack_map_cells(map, where)
        whole = map.with(first_pixel: 0, pixel_count: nil)
        cells = pack_slot_values(whole, map.shape, where)
        map.run_of_numbers? ? cells.slice(map.first_pixel, map.pixel_count) : cells
      end

      # Each table of +size+ colours of +colors+ (a whole slot of colours), as the colours
      # themselves: what a tile drawn from the whole table picks from, by bank.
      def pack_color_tables(colors, size, where) = pack_slot_values(colors, :colors, where).each_slice(size).to_a

      # THE CELLS THE BACKGROUND MAY BE WRITTEN LATER (`set_cells:`), each a cell number in the
      # map's layout: a list of them, a Range (a run of tiles in one bank, turned one way), or a
      # list of both. On a map of map cells a number is the record's (Original::MapCell.number),
      # and a told cell may be given as the record itself, an Original::MapCell::Cell. The original writes words onto a screen by storing font cells in its map, and no
      # cell of the map names a font tile until then, so the pictures the map needs do not hold
      # them. Each told cell's tiles are made pictures here as the map's were and kept in +pictures+
      # with them, by tile as drawn, so a tile the map also draws is one picture. The block makes
      # the picture of a tile, given the tile and its number.
      #
      # A tile that draws nothing is left empty in the map, and `set_tile` has no key for an empty
      # cell. So a told tile that draws nothing is given a picture, see-through all over: the
      # font's space, which the original writes to take its words away again. A build that reads
      # its pack as the game starts cannot tell that a tile draws nothing, so its block always
      # makes a picture and none is made here.
      #
      # Where the map's cells are +big+ pictures of 16x16 (#big_pack_cells?), a told cell is one
      # such picture, kept in +pictures+ by its four tiles, and the block makes it given those.
      #
      # Hands back a DSL::PackCells for the background's handle, or nil where none are told.
      def declare_pack_cells_written_later(name, set_cells, words, tiles_a_side, pictures, bank_lists, big: false, &)
        return nil if set_cells.nil?

        tiles_by_word = {}
        cells = DSL::PackCells.new(format: words, side: big ? 1 : tiles_a_side, tiles_by_word: tiles_by_word)
        pack_cell_words!(name, set_cells, cells).each do |word|
          next tiles_by_word[cells.read_part(word)] ||= [told_big_cell(name, words, word, pictures, bank_lists, &)] if big

          tiles_by_word[cells.read_part(word)] ||= Array.new(tiles_a_side * tiles_a_side) do |at|
            tile = words.cell_tile(word, at % tiles_a_side, at / tiles_a_side, tiles_a_side)
            pictures[tile] = yield(tile, pictures.length) unless pictures.key?(tile)
            pictures[tile] || (pictures[[:blank, tile.bank]] ||= pack_background_blank_tile(name, tile.bank, bank_lists))
          end
        end
        cells
      end

      # The picture of 16x16 of the told cell +word+, made by the block where the map has none
      # yet; a cell that draws nothing is see-through all over, as a told 8x8 tile is.
      def told_big_cell(name, words, word, pictures, bank_lists)
        quarters = pack_cell_quarters(words, word)
        pictures[quarters] = yield(quarters, pictures.length) unless pictures.key?(quarters)
        bank = quarters.first.bank
        pictures[quarters] ||
          (pictures[[:big_blank, bank]] ||= pack_background_blank_tile(name, bank, bank_lists, side: 2 * Original::Slot::TILE_SIDE))
      end

      # The cell numbers +set_cells+ names, in the order given, each in the layout of +cells+ (a
      # DSL::PackCells): a number, or on a map of map cells an Original::MapCell::Cell too.
      def pack_cell_words!(name, set_cells, cells)
        parts = set_cells.is_a?(Array) ? set_cells : [set_cells]
        told = parts.flat_map { |part| pack_cell_run?(part, cells.most_number) ? part.to_a : [cells.number_of!(part, name)] }
        return told if !told.empty? && told.all? { |word| word.is_a?(Integer) && word.between?(0, cells.most_number) }

        raise ArgumentError, pack_cell_words_message(name, set_cells, cells)
      end

      def pack_cell_words_message(name, set_cells, cells)
        unless cells.map_cells?
          return "background :#{name} was given set_cells: #{set_cells.inspect}. It takes the cell numbers that set_cell can " \
                 "write later, each a number of two bytes as the original's map holds them: a list like `[0xE500, 0xE501]`, " \
                 "or a range like `0xE500..0xE553`."
        end

        "background :#{name} was given set_cells: #{set_cells.inspect}. It takes the map cells that set_cell can write " \
          "later. Each is a map cell like `VBlank::Original::MapCell::Cell.new(tile: 256, bank: 1)`, or that cell as one " \
          "number from 0 to #{Kernel.format('0x%X', cells.most_number)}, like `VBlank::Original::MapCell.number(tile: 256, " \
          "bank: 1)`. Give a list of them, or a range of numbers."
      end

      # Is +part+ of a `set_cells:` a run of cell numbers, written as a Range of them, none above +most+?
      def pack_cell_run?(part, most)
        part.is_a?(Range) && part.begin.is_a?(Integer) && part.end.is_a?(Integer) && part.begin >= 0 && part.end <= most
      end

      # A picture that draws nothing, for a told cell whose tile is see-through all over. It is
      # drawn from the list of +bank+ as the tile it stands for is, so it brings no colours of its own.
      def pack_background_blank_tile(name, bank, bank_lists, side: Original::Slot::TILE_SIDE)
        list = bank_lists.fetch(bank) do
          raise ArgumentError, "background :#{name} was told a cell drawn from bank #{bank} of colors, and its colors: " \
                               "slot holds #{bank_lists.length} banks. To fix this, give it a slot that holds every bank " \
                               "its cells use."
        end
        picture = side == Original::Slot::TILE_SIDE ? :"background :#{name} blank tile #{bank}" : :"background :#{name} blank cell #{bank}"
        # It draws no place, so it needs none of its bank's colours: a console that keeps a list of
        # colours a tile gives it the backdrop's alone, not a list for a bank the map may not use.
        image picture, width: side, height: side, places: Array.new(side * side, 0), colors: list
        picture
      end

      # The most tiles a background read as the game starts can be: each cell's tile is a tile of
      # its own, and a build for a computer keeps a cell's tile in sixteen signed bits.
      MOST_TILES_READ_AT_START = 0x7FFF
      # How many bytes of the file a colour is, in every layout a slot of colours is kept in.
      COLOR_BYTES = 2

      # THE SAME BACKGROUND WITH THE PACK LEFT OUT (see the top of this file). It is declared as a
      # background of the right size whose tiles are a picture for each bank of the slot, drawn
      # from that bank's list, so `draw_with` finds every bank by its name; the pictures and the
      # map's cells are stand-ins nothing draws, and the node says where in the file the real ones
      # are. A bank's list holds no colours here, only a marker for each (IR::StartFile, "MARKERS").
      #
      # THE CELLS IT MAY BE WRITTEN LATER (`set_cells:`) are known here though the map's are not:
      # a told number names its tile, its turn and its bank, and only the tile's pixels are in the
      # file. So each told tile is a picture of the background's tileset after the banks'
      # stand-ins and the runs of any tiles that take turns, read from the file as any picture of
      # a tile from the pack is (#declare_told_tile_read_at_start), and `set_cell` writes it by its
      # key as it does built all-in-one. A told tile that takes turns is its run's tile instead.
      # The tiles the map draws come after them, made as the game starts.
      def declare_pack_background_read_at_start(name, tiles:, map:, colors:, across:, tiles_a_side:, words:, moving:, set_cells: nil,
                                                **others)
        made = pack_tiles_held_at_start(name, tiles: tiles, map: map, colors: colors, across: across, tiles_a_side: tiles_a_side,
                                              words: words, moving: moving, set_cells: set_cells, first: 0)
        where = made.where
        refuse_oversized_map_at_start!(name, [where], made.held.length)
        tileset = :"background :#{name} tiles"
        tiles(tileset, made.held.to_h { |picture| [picture, picture] })
        handle = background(name, tiles: tileset, map: Array.new(where.rows) { Array.new(where.columns, made.held.first) }, **others)
        @backgrounds.fetch(name).node.from_file = [where]
        # The told cells' tiles are known here, and the map's are marked as the file is read.
        mark_tiles_in_front(name, made.told) if words.reads_front
        return handle.allow_undrawn_lists([]) if drawn_from_whole_table?(tiles)

        # Which bank the map uses is in the file, so one list given alone is every bank's.
        handle.allow_one_list_for_every_bank.allow_set_cells(made.cells)
      end

      # THE SAME BACKGROUND WALKING BETWEEN AREAS, WITH THE PACK LEFT OUT: each area's tiles held
      # as one background's are (#pack_tiles_held_at_start), its pictures named for the area and
      # numbered after the areas' before it, and the areas one background walking between
      # tilesets (Builder::Tiled#background_from_sets), each area's map the size of its own and
      # naming its first stand-in. The node keeps a record of the file for each area, in order,
      # and each backend that plays it reads every area's cells as the game starts, each area's
      # record holding its own width. +slots+ are each area's tiles:, map:, colors: and across:, by
      # area.
      def declare_pack_areas_read_at_start(name, slots, cell:, set_cells: nil, **others)
        first = 0
        made = slots.to_h do |area, given|
          own = :"#{name}'s area :#{area}"
          told = set_cells.is_a?(Hash) ? set_cells[area] : set_cells
          words, moving = refuse_bad_pack_area!(own, cell: cell, set_cells: told, **given)
          part = pack_tiles_held_at_start(own, **given, tiles_a_side: cell / Original::Slot::TILE_SIDE, words: words,
                                               moving: moving, set_cells: told, first: first)
          first += part.held.length
          [area, part]
        end
        # Every area's tiles are one background's, and areas drawn from the same art keep its tiles once.
        refuse_oversized_map_at_start!(name, made.values.map(&:where), first)
        tilesets = made.to_h do |area, part|
          tileset = :"background :#{name}'s area :#{area} tiles"
          tiles(tileset, part.held.to_h { |picture| [picture, picture] })
          [area, tileset]
        end
        maps = made.transform_values { |part| Array.new(part.where.rows) { Array.new(part.where.columns, part.held.first) } }
        handle = background(name, tiles: tilesets, map: maps, **others)
        node = @backgrounds.fetch(name).node
        node.from_file = made.values.map(&:where)
        return handle.allow_undrawn_lists([]) if drawn_from_whole_table?(slots.values.first[:tiles])

        handle.allow_one_list_for_every_bank
        return handle if set_cells.nil?

        handle.allow_set_cells_by_area(made.values.map(&:cells), node.tiles)
      end

      # What a build reading its pack as the game starts holds for one background, or one area of
      # one: where its map, tiles and colours are in the file (an IR::StartFile::Background), the
      # pictures it holds in order (a stand-in for each bank, the runs of tiles that take turns,
      # the told cells' tiles), the told tiles by tile as drawn, and the cells `set_cell` may write
      # (a DSL::PackCells).
      HeldAtStart = Data.define(:where, :held, :told, :cells)

      # The pictures and record of #declare_pack_background_read_at_start, for a background or an
      # area +name+ whose held tiles start at tile +first+ of the background's. Hands back a HeldAtStart.
      def pack_tiles_held_at_start(name, tiles:, map:, colors:, across:, tiles_a_side:, words:, moving:, set_cells:, first:)
        subject = "background :#{name}"
        [[tiles, "tiles:"], [map.with(first_pixel: 0, pixel_count: nil), "map:"], [colors, "colors:"]].each do |slot, what|
          refuse_slot_from_elsewhere!(slot, "#{subject}'s #{what}")
        end
        bank_size = tiles.layout.format.colors
        first_tile = tiles.tile_index || 0
        # Tiles drawn from the whole table have no list of colours, so no bank has a name.
        whole_table = drawn_from_whole_table?(tiles)
        where = IR::StartFile::Background.new(
          # A run of a slot starts so many numbers into it; a whole slot, none.
          map_at: @pack_slot_starts.fetch(map.layout.name) + (map.first_pixel * map.layout.item_bytes),
          cells: map.count, across: across, cell_tiles: tiles_a_side,
          number_format: map.layout.format, map_words: words,
          tiles_at: @pack_slot_starts.fetch(tiles.layout.name) + (first_tile * tiles.layout.item_bytes),
          tile_count: tiles.layout.count - first_tile, tile_format: tiles.layout.format,
          colors_at: @pack_slot_starts.fetch(colors.layout.name), bank_count: colors.count / bank_size, bank_size: bank_size,
          color_format: colors.layout.format,
          bank_names: whole_table ? [].freeze : Array.new(colors.count / bank_size) { |bank| :"#{colors.layout.name}_#{bank}" }
        )
        stand_ins = if whole_table
                      [declare_table_stand_in(name)]
                    else
                      where.bank_names.each_with_index.map { |list, bank| declare_bank_stand_in(name, list, bank, where, subject) }
                    end
        # The tiles that take turns through pictures follow, each a tile of a run (PackTilePictures).
        unless moving.empty?
          runs, where = declare_pack_tile_runs_at_start(name, moving, where, first + stand_ins.length)
          (@run_tiles_read_at_start ||= Set.new).merge(runs)
        end
        told = {}
        places = []
        if set_cells.is_a?(DSL::PackSlot)
          places, where = declare_told_slot_read_at_start(name, set_cells, where, first + [*stand_ins, *runs].uniq.length)
          cells = DSL::PackCells.new(format: words, side: tiles_a_side, tiles_by_word: {}, place_tiles: places.zip)
        else
          cells = declare_pack_cells_written_later(name, set_cells, words, tiles_a_side, told, where.bank_names) do |tile, number|
            # A told tile that takes turns is the run's tile for its bank and turn, as the map's are.
            if moving.key?(tile.tile) && tile.bank < where.bank_count
              next pack_run_tile_read_at_start(runs, where, first + stand_ins.length, tile)
            end

            declare_told_tile_read_at_start(name, tile, where, number)
          end
        end
        HeldAtStart.new(where: where, held: [*stand_ins, *runs, *told.values, *places].uniq, told: told, cells: cells)
      end

      # THE CELLS A SLOT TELLS A BACKGROUND READ AS THE GAME STARTS (`set_cells: pack[:changes]`).
      # Which tile, bank and turn each is, is in the file, so the build holds a stand-in tile for
      # each place of the slot, from tile +first+ of the background's own on, and the background's
      # fill paints each from its cell as it paints a cell of the map, in every set of colours the
      # background is drawn in and following its bank's list (IR::StartFile::Background#told_at).
      # A stand-in is see-through and of no list, so nothing takes it for a bank's tile. Hands back
      # the stand-ins' names, a place's first, and +where+ told where the slot is.
      def declare_told_slot_read_at_start(name, slot, where, first)
        side = Original::Slot::TILE_SIDE
        places = Array.new(slot.count) do |place|
          picture = :"background :#{name} told place #{place}"
          image picture, width: side, height: side, places: Array.new(side * side, 0), colors: [:black]
          picture
        end
        (@told_places_read_at_start ||= Set.new).merge(places)
        [places, where.with(told_at: @pack_slot_starts.fetch(slot.layout.name), told_count: slot.count, told_first: first)]
      end

      # The tile of +runs+ (the run tiles a background read as the game starts holds from tile
      # +first+ on) that a cell naming +tile+ (a Console::CellTile that takes turns) shows: the one
      # the start of the game points such a map cell at (IR::StartFile::MovingTile#tile_of).
      def pack_run_tile_read_at_start(runs, where, first, tile)
        key = where.moving.find { |moving_tile| moving_tile.tile == tile.tile }
        runs.fetch(key.tile_of(tile.bank, tile.mirrored, tile.upside_down) - first)
      end

      # THE ONE TILE THE BUILD HOLDS FOR A BACKGROUND DRAWN FROM THE WHOLE TABLE, read as the game
      # starts: a background has a tile, and its map names one, until the file is read and each
      # cell names the tile it draws. Nothing draws it. It holds a colour of its own and no list,
      # since tiles of 256 colours have no bank to name (#drawn_from_whole_table?).
      def declare_table_stand_in(name)
        side = Original::Slot::TILE_SIDE
        picture = :"background :#{name} stand-in"
        image picture, width: side, height: side, data: Array.new(side * side, :black)
        picture
      end

      # THE PICTURE OF A TOLD TILE (a Console::CellTile) of a background read as the game starts
      # (+where+, an IR::StartFile::Background): its places are the tile's, read from the file and
      # turned as the tile says once read, and its colours the list of its bank, a marker each. So
      # it is drawn with whatever list the background draws that bank with, as the map's tiles are.
      #
      # Whether the tile draws nothing is in the file, so it is always a picture: one that is
      # see-through all over when the file says so, which is what a font's space is.
      #
      # The slot's size and how many banks its colours hold are the game's own words, so a told
      # tile past either is refused here as it is built all-in-one.
      def declare_told_tile_read_at_start(name, tile, where, number)
        unless tile.tile < where.tile_count
          raise ArgumentError, "background :#{name} draws tile #{tile.tile}, and its tiles: slot holds #{where.tile_count} " \
                               "tiles from there. To fix this, give it a slot that holds every tile it draws."
        end
        list = where.bank_names.fetch(tile.bank) do
          raise ArgumentError, "background :#{name} was told a cell drawn from bank #{tile.bank} of colors, and its colors: " \
                               "slot holds #{where.bank_count} banks. To fix this, give it a slot that holds every bank " \
                               "its cells use."
        end
        side = Original::Slot::TILE_SIDE
        picture = :"background :#{name} told tile #{number}"
        node = Build.bitmap(picture, width: side, height: side, pixels: Array.new(side * side, 0).pack("v*"), transparent: nil,
                                     colors: [0, *@color_lists.fetch(list).drop(1)], places: Array.new(side * side, 1).pack("C*"),
                                     colors_name: list)
        node.from_file = IR::StartFile::Picture.new(
          colors_at: nil, colors_count: where.bank_size, tile_format: where.tile_format, turns: tile.turns.freeze,
          places_at: where.tiles_at + (tile.tile * where.tile_format.tile_bytes)
        )
        record_picture(node)
        (@pictures_from_start_file ||= {})[picture] = node.from_file
        record_visible_bounds(name: picture, width: side, height: side, cells: [], transparent: nil)
        picture
      end

      # A picture standing in for the tiles drawn from bank +bank+ of a background read as the game
      # starts (+where+, an IR::StartFile::Background): a tile of the list +list+. Nothing draws it.
      # The list is declared as `colors :list, pack[:slot].bank(n)` declares one in such a build,
      # a marker for each colour of the bank (DataPacks#pack_colors_read_at_start), so the game
      # walks it, recolours with it and draws pictures in it by its name. A list of that name made
      # by another background from the slot is the same list; one the game declared itself is refused.
      def declare_bank_stand_in(name, list, bank, where, subject)
        held = Array.new(where.bank_size) do |place|
          at = where.colors_at + (((bank * where.bank_size) + place) * COLOR_BYTES)
          start_file_color_marker(IR::StartFile::Color.new(at: at, format: where.color_format))
        end
        refuse_pack_color_list_taken!("#{subject}'s colors:", list) if @color_lists.key?(list) && @color_lists[list] != held
        @color_lists[list] = held
        (@color_lists_read_at_start ||= {})[list] = bank
        side = Original::Slot::TILE_SIDE
        picture = :"background :#{name} bank #{bank}"
        node = Build.bitmap(picture, width: side, height: side, pixels: Array.new(side * side, 0).pack("v*"), transparent: nil,
                                     colors: [0, *held.drop(1)], places: Array.new(side * side, 1).pack("C*"),
                                     colors_name: list)
        record_picture(node)
        record_visible_bounds(name: picture, width: side, height: side, cells: [], transparent: nil)
        picture
      end

      # `colors :name` for a name a bank read as the game starts has already.
      def refuse_color_list_named_as_bank!(name)
        return unless @color_lists_read_at_start&.key?(name)

        raise ArgumentError, "colors :#{name} has the name of a bank of colors that a background reads from the data " \
                             "pack. To fix this, give the game's own list another name."
      end

      # A CELL OF A BACKGROUND READ AS THE GAME STARTS IS CHANGED ONLY TO A TILE IT WAS TOLD
      # (`set_cells:`, written with `set_cell`): the tile a `set_tile` line names is a number among
      # the background's tiles, and which tiles its map draws is in the file. The told cells'
      # tiles are the ones known here, each a picture read from the file; a line that can put any
      # other tile there (a bank's stand-in, which nothing draws) is refused. Checked once the
      # whole program is declared, since a routine's lines are built last.
      def refuse_set_tile_read_at_start!
        return unless pack_left_out?

        read = @program.walk.select { |node| node.kind == :background && node.from_file }.group_by(&:name)
        changed = @program.walk.find do |node|
          next false unless node.kind == :set_tile && read.key?(node.name)

          put = node.picked? ? node.picks.compact : [node.tile]
          read.fetch(node.name).any? { |background| put.any? { |tile| !told_cell_tile_at_start?(background.tiles[tile]) } }
        end
        return unless changed

        raise ArgumentError, "background :#{changed.name} is told `set_tile`. Its tiles and map are read from the data " \
                             "pack as the game starts, so the build does not know which tiles its map has. To fix this, " \
                             "name the cells in the background's `set_cells:` and write them with `set_cell`, or build " \
                             "the game all-in-one."
      end

      # Is +picture+ a tile of a background read as the game starts that a told cell can show: a
      # told tile's picture read from the file, or a tile of a run that takes turns?
      def told_cell_tile_at_start?(picture)
        picture_from_start_file?(picture) || @run_tiles_read_at_start&.include?(picture) || @told_places_read_at_start&.include?(picture) || false
      end

      # The tiles a background read as the game starts keeps for its maps (+records+, its
      # IR::StartFile::Background records): its slots' tiles once each, as places, and a table of
      # colours for each bank (IR::StartFile.cell_tile_pools). +held+ is how many tiles the build
      # holds for it besides: a stand-in for each bank, the runs of tiles that take turns, and the
      # told cells'. Those and the tables are numbered among the background's tiles, and each
      # different tile as drawn the maps name is numbered after them as the file is read, so the
      # build leaves room for those and the runtime stops the game in plain words if a map names
      # more than that room. The build cannot count them itself: which tiles, banks and turns a map
      # names is in the player's copy, and a build that leaves its pack out never reads it (the
      # most the slots could name, every tile in every bank and turn, is more than a cell can
      # number for any slot of an original's size, so refusing by it would refuse every such game).
      def refuse_oversized_map_at_start!(name, records, held)
        pools = IR::StartFile.cell_tile_pools(records)
        tables = pools.sum(&:tables)
        kept = held + tables
        if kept > MOST_TILES_READ_AT_START - TILES_LEFT_FOR_MAPS || tables > MOST_TABLE_TILES
          raise ArgumentError, "background :#{name} reads its maps from the data pack as the game starts, and holds " \
                               "#{kept} tiles before its maps name any. Such a background can hold " \
                               "#{MOST_TILES_READ_AT_START - TILES_LEFT_FOR_MAPS} at most, and tables of colors for " \
                               "#{MOST_TABLE_TILES} tiles. To fix this, tell it fewer cells in set_cells:, give it fewer " \
                               "slots of colors, or build the game all-in-one."
        end
        return if pools.sum(&:places) <= MOST_PLACE_TILES

        raise ArgumentError, "background :#{name} reads its maps from the data pack as the game starts, and its slots " \
                             "of tiles hold #{pools.sum(&:places)} tiles. Such a background can read #{MOST_PLACE_TILES} " \
                             "at most. To fix this, give its areas fewer slots of tiles, or build the game all-in-one."
      end

      # Room among a background's tiles for the tiles as drawn its maps name, read as the game starts:
      # a few thousand, as a console's video memory holds.
      TILES_LEFT_FOR_MAPS = 4096
      # How many tiles of tables of colours, and of places, a cell read as the game starts can name
      # (each runtime's record of a tile as drawn keeps them in 12 and 16 bits).
      MOST_TABLE_TILES = 4096
      MOST_PLACE_TILES = 65_536

      # The picture of +tile+ (a Console::CellTile), drawn from the list of its bank. Nil for a tile
      # that draws nothing, left empty in the map.
      def pack_background_tile(name, tile, tile_places, bank_lists, number)
        side = Original::Slot::TILE_SIDE
        places = pack_tile_at(tile_places, tile.tile, "background :#{name}")
        return nil if places.all?(&:zero?)

        rows = turned_rows(places.each_slice(side).to_a, mirrored: tile.mirrored, upside_down: tile.upside_down)
        list = pack_bank_list(name, tile.bank, bank_lists)
        picture = :"background :#{name} tile #{number}"
        if list.is_a?(Array)
          # A table of colours, not a list's name: the picture holds its colours itself.
          image picture, width: side, height: side, transparent: true,
                         data: rows.flatten.map { |place| place.zero? ? :transparent : list.fetch(place) }
        else
          define_pack_bank_tile(picture, rows.flatten, list)
        end
        picture
      end

      # A TILE DRAWN FROM A BANK KEEPS THE ORIGINAL'S PLACES (Nodes::Bitmap#places_from_pack), as a
      # picture whose places are a slot's own does. A console that keeps one list of colours for
      # each tile, the Color, then draws every tile of a bank from one list holding the bank's
      # colours where the bank holds them, as the original does: however many of the bank's places
      # a tile draws, a screen the original drew in seven banks takes seven of its eight lists.
      # Every other console draws it as any picture drawn by place from a list.
      def define_pack_bank_tile(picture, places, list, side: Original::Slot::TILE_SIDE)
        define_placed_image(picture, places: places, width: side, height: side, colors: declared_colors_for_image!(picture, list),
                                     colors_name: list, places_from_pack: true)
      end

      # The list of bank +bank+ of +bank_lists+, for a cell of the map of background +name+.
      def pack_bank_list(name, bank, bank_lists)
        bank_lists.fetch(bank) do
          raise ArgumentError, "background :#{name} has a cell drawn from bank #{bank} of colors, and its colors: " \
                               "slot holds #{bank_lists.length} banks. To fix this, give it a slot that holds every bank " \
                               "its map uses."
        end
      end

      # Each bank of +colors+ (a whole slot of colours), +size+ colours to a bank, as a list named
      # `:<slot>_<bank>`. A list of that name made by another background from the slot is the same
      # list; one the game declared itself is refused. Hands back the names, by bank.
      def declare_pack_color_banks(colors, size, subject)
        values = pack_slot_values(colors, :colors, subject)
        values.each_slice(size).each_with_index.map do |bank, index|
          list = :"#{colors.layout.name}_#{index}"
          if !@color_lists.key?(list)
            colors(list, bank)
          elsif @color_lists[list] != colors_of_list(bank)
            refuse_pack_color_list_taken!(subject, list)
          end
          list
        end
      end

      # A bank's colours as `colors` keeps a list of them.
      def colors_of_list(bank) = bank.map { |color| Graphics::Color.resolve(color) }

      def refuse_pack_color_list_taken!(subject, list)
        raise ArgumentError, "#{subject} names its colors :#{list}, and the game has a list of that name with other colors. " \
                             "To fix this, give the game's own list another name."
      end

      def refuse_pack_background_drawing_nothing!(name)
        raise ArgumentError, "background :#{name} draws nothing. Every tile its map names is see-through. To fix this, give " \
                             "it the map of a screen, or leave the background out."
      end

      # map: is a slot of numbers a cell each, or a run of one: two bytes wide in the layout of
      # the original's console, or one byte wide, each a tile's number (Console::BYTE_MAP_CELLS).
      def refuse_map_not_of_cells!(name, map)
        return if map.is_a?(DSL::PackSlot) && map.shape == :map_cells
        return if map.is_a?(DSL::PackSlot) && map.shape == :numbers && %i[half byte].include?(map.layout.width)

        raise ArgumentError, "background :#{name} needs map:, a slot of map cells that the unpacking writes, like " \
                             "`slots.map_cells :map, count: 1024`. It can also be a slot of numbers, one a cell: two " \
                             "bytes wide in the layout of the original's console, like `slots.numbers :map, count: 512, " \
                             "width: :half, signed: false`, or one byte wide for a map that holds only tile numbers, " \
                             "like `slots.numbers :map, count: 1024, width: :byte, signed: false`."
      end

      # A CELL OVER TILES OF 256 COLOURS HAS NO BANK. Such a tile picks from the whole table, so
      # the cell's bank bits pick nothing: the Advance keeps a text layer of 256 colours under its
      # usual cells of two bytes and does not read their bank bits, and a map cell's bank is read
      # the same way. So the cell is read for its tile and its turns alone, by the build here, by
      # the interpreter and by each runtime as the game starts (IR::StartFile::Background).
      def cell_format_without_banks(words) = words.with(bank_at: 0, bank_bits: 0)

      # A MAP CELL the unpacking wrote is VBlank's own record, so a bank other than 0 in it over
      # tiles of 256 colours is a mistake in the unpacking: it names a bank that is not there.
      # A console's own cells keep bank bits that console does not read under such tiles, so those
      # are not refused. A build that leaves its pack out never reads the map, and draws such a
      # cell from the table as if its bank were 0.
      def refuse_banks_over_table_tiles!(name, tiles, map, cells)
        return unless drawn_from_whole_table?(tiles) && map.shape == :map_cells

        banks = cells.map { |cell| Original::MapCell::FORMAT.bank_of(cell) }
        at = banks.index(&:positive?)
        return unless at

        raise ArgumentError, "background :#{name} has map cell #{at} in bank #{banks.fetch(at)} of its colors: slot. Its " \
                             "tiles have #{tiles.layout.format.colors} colors, and each pixel of such a tile picks from " \
                             "the whole colors: slot. So a map cell over such a tile has no bank. To fix this, write " \
                             "bank 0 for each map cell in the unpacking, or leave out bank:."
      end

      # A tile of 256 colours can name any place of the table, so the slot holds all of it.
      def refuse_colors_short_of_table!(name, tiles, colors)
        size = tiles.layout.format.colors
        return unless drawn_from_whole_table?(tiles) && colors.count < size

        raise ArgumentError, "background :#{name} has tiles of #{size} colors, and its colors: slot holds #{colors.count} " \
                             "colors. A pixel of such a tile can be any of #{size} colors. To fix this, give colors: a " \
                             "slot of #{size} colors."
      end

      # A cell written later is a tile of a bank's list, and tiles of 256 colours have no list.
      def refuse_set_cells_of_table_tiles!(name, tiles, set_cells)
        return if set_cells.nil? || !drawn_from_whole_table?(tiles)

        raise ArgumentError, "background :#{name} was given set_cells:, and its tiles have #{tiles.layout.format.colors} " \
                             "colors. VBlank does not write a cell of such a background later. To fix this, remove " \
                             "set_cells:, or show another map with `show_map`."
      end

      def refuse_colors_not_whole_slot!(name, colors)
        return if colors.is_a?(DSL::PackSlot) && colors.shape == :colors && !colors.bank?

        raise ArgumentError, "background :#{name} needs colors:, a whole slot of colors, like `pack[:palette]`. A cell " \
                             "names its bank of colors by counting from the slot's first color."
      end

      # The layout of a cell of +map+: VBlank's own record (Original::MapCell), which any original's
      # unpacking can write; a byte that is a tile's number, in any original; or the two bytes the
      # original's console keeps, a shortcut for a port of a console whose layout VBlank knows.
      def pack_map_word_format!(name, map)
        return Original::MapCell::FORMAT if map.shape == :map_cells
        return Console::BYTE_MAP_CELLS if map.layout.width == :byte

        Console.original_formats_of(@data_pack_platform)&.map_words or
          raise ArgumentError, "background :#{name} reads a map of numbers two bytes wide from the data pack, and VBlank " \
                               "does not know how this original's console keeps a cell in two bytes. To fix this, give " \
                               "map: a slot of map cells, like `slots.map_cells :map, count: 1024`, and write each cell " \
                               "into it in the unpacking with `pack[:map].write_cell(at, tile:, bank:, mirrored:, " \
                               "upside_down:)`."
      end

      def refuse_bad_pack_background_shape!(name, map, across, cell, words)
        cells = map.is_a?(DSL::PackSlot) ? map.count : 0
        sides = words.row_tiles ? [8, 16] : [8]
        unless across.is_a?(Integer) && across.positive? && (cells % across).zero?
          raise ArgumentError, "background :#{name} needs across:, how many cells a row of its map holds, a whole number " \
                               "its map's #{cells} cells divide by. Got #{Messages::PlainWords.words_for_given(across)}. " \
                               "Or give map: a map that carries its width, like `pack[:map].as_map(across: 32)`."
        end
        return if sides.include?(cell)

        maps = words.cell_bytes == Original::MapCell::BYTES ? "a map of map cells" : "this original's maps"
        raise ArgumentError, "background :#{name} was given cell: #{cell.inspect}. A cell of #{maps} is " \
                             "#{sides.join(' or ')} pixels square."
      end
    end
  end
end
