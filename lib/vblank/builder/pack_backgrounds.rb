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
    # keeps them. Each number of the map is a cell in the layout of the console the original is for
    # (Console::MapWordFormat): which tile, mirrored or upside down, and which bank of colours.
    #
    # THE COLOURS ARE NAMED LISTS, a bank each. Bank +n+ of the slot is the list `:<slot>_<n>`
    # (`:title_colors_0`), so a game fades the background or draws it with other colours by those
    # names, as it would a background of its own (`city.draw_with color_walk(:title_colors_0, from:
    # :black), showing: step`). Two backgrounds from one slot share its lists.
    #
    # BUILT ALL-IN-ONE, the cells are worked out here from what the slots hold, as a port would
    # have worked them out by hand: each different tile as drawn (a tile, its bank and its turn) a
    # picture of 8x8, and the map those pictures, a big cell its tiles. So the console, the
    # interpreter and every build draw it as any background, and a tile that draws nothing is
    # left empty. With the pack left out nothing here can be known, and the build says so.
    module PackBackgrounds
      private

      # The background +name+ from +tiles+, +map+ and +colors+ (DSL::PackSlot handles), +across+
      # cells to a row of the map, each cell +cell+ pixels square. +others+ are the background's
      # own settings, handed on.
      def declare_pack_background(name, tiles:, map:, colors:, across:, cell:, **others)
        refuse_pack_background_left_out!(name)
        subject = "background :#{name}"
        tile_places = pack_tile_places(tiles, subject)
        refuse_map_not_of_halves!(name, map)
        refuse_colors_not_whole_slot!(name, colors)
        words = pack_map_word_format!(name)
        refuse_bad_pack_background_shape!(name, map, across, cell, words)
        bank_lists = declare_pack_color_banks(colors, tiles.layout.format.colors, "#{subject}'s colors:")
        pictures = {}
        tiles_a_side = cell / Original::Slot::TILE_SIDE
        rows = pack_slot_values(map, :numbers, "#{subject}'s map:").each_slice(across).flat_map do |row|
          Array.new(tiles_a_side) do |down|
            row.flat_map do |word|
              Array.new(tiles_a_side) do |along|
                tile = PackCellTile.of(word, words, along, down, tiles_a_side)
                pictures.fetch(tile) { pictures[tile] = pack_background_tile(name, tile, tile_places, bank_lists, pictures.length) }
              end
            end
          end
        end
        drawn = pictures.values.compact
        refuse_pack_background_drawing_nothing!(name) if drawn.empty?
        tileset = :"background :#{name} tiles"
        tiles(tileset, drawn.to_h { |picture| [picture, picture] })
        background(name, tiles: tileset, map: rows, **others)
      end

      # ONE TILE OF A CELL, as it is drawn: which tile of the slot, turned how, from which bank. A
      # cell bigger than a tile is drawn as its tiles, each a cell of the map built here, so every
      # console draws it with the tiles it has; a cell turned over turns each of its tiles and
      # swaps them about, as the console turns the whole cell.
      PackCellTile = Data.define(:tile, :bank, :mirrored, :upside_down) do
        # The tile at +along+ and +down+ (in tiles, from the cell's top left as drawn) of the cell
        # +word+ stands for, in the layout +words+, a cell +side+ tiles square.
        def self.of(word, words, along, down, side)
          mirrored = words.mirrored?(word)
          upside_down = words.flipped?(word)
          from_along = mirrored ? side - 1 - along : along
          from_down = upside_down ? side - 1 - down : down
          new(tile: words.tile_of(word) + (from_down * (words.row_tiles || 0)) + from_along, bank: words.bank_of(word),
              mirrored: mirrored, upside_down: upside_down)
        end
      end

      # The picture of +tile+ (a PackCellTile), drawn from the list of its bank. Nil for a tile that
      # draws nothing, left empty in the map.
      def pack_background_tile(name, tile, tile_places, bank_lists, number)
        side = Original::Slot::TILE_SIDE
        places = pack_tile_at(tile_places, tile.tile, "background :#{name}")
        return nil if places.all?(&:zero?)

        rows = turned_rows(places.each_slice(side).to_a, mirrored: tile.mirrored, upside_down: tile.upside_down)
        list = bank_lists.fetch(tile.bank) do
          raise ArgumentError, "background :#{name} has a cell drawn from bank #{tile.bank} of colors, and its colors: " \
                               "slot holds #{bank_lists.length} banks. To fix this, give it a slot that holds every bank " \
                               "its map uses."
        end
        picture = :"background :#{name} tile #{number}"
        image picture, width: side, height: side, places: rows.flatten, colors: list
        picture
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

      def refuse_map_not_of_halves!(name, map)
        return if map.is_a?(DSL::PackSlot) && map.shape == :numbers && map.layout.width == :half

        raise ArgumentError, "background :#{name} needs map:, a slot of numbers two bytes wide, one a cell, like " \
                             "`slots.numbers :map, count: 512, width: :half, signed: false`."
      end

      def refuse_colors_not_whole_slot!(name, colors)
        return if colors.is_a?(DSL::PackSlot) && colors.shape == :colors && !colors.bank?

        raise ArgumentError, "background :#{name} needs colors:, a whole slot of colors, like `pack[:palette]`. A cell " \
                             "names its bank of colors by counting from the slot's first color."
      end

      # The layout of a cell of the original's maps, the one its console keeps.
      def pack_map_word_format!(name)
        formats = Console.for(@data_pack_platform).original_formats if Console::KITS.key?(@data_pack_platform)
        formats&.map_words or
          raise ArgumentError, "background :#{name} reads a map from the data pack, and VBlank does not know how a cell of " \
                               "this original's maps is kept. A map from the pack is read in the layout of the Advance, " \
                               "the Super Nintendo or the Genesis."
      end

      def refuse_pack_background_left_out!(name)
        return unless pack_left_out?

        raise ArgumentError, "background :#{name} reads its tiles, map and colors from the data pack, and this build reads " \
                             "its pack as the game starts. A background from the pack is not made that way yet. To fix " \
                             "this, build the game all-in-one."
      end

      def refuse_bad_pack_background_shape!(name, map, across, cell, words)
        cells = map.is_a?(DSL::PackSlot) ? map.count : 0
        sides = words.row_tiles ? [8, 16] : [8]
        unless across.is_a?(Integer) && across.positive? && (cells % across).zero?
          raise ArgumentError, "background :#{name} needs across:, how many cells a row of its map holds, a whole number " \
                               "its map's #{cells} cells divide by. Got #{across.inspect}."
        end
        return if sides.include?(cell)

        raise ArgumentError, "background :#{name} was given cell: #{cell.inspect}. A cell of this original's maps is " \
                             "#{sides.join(' or ')} pixels square."
      end
    end
  end
end
