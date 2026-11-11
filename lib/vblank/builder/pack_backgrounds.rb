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
    # :black), showing: step`). Two backgrounds from one slot share its lists. `draw_with` takes any
    # bank of the slot, and one this background's map does not use changes nothing: which banks a
    # map uses is in the player's copy, so a game names every bank its screen fades.
    #
    # BUILT ALL-IN-ONE, the cells are worked out here from what the slots hold, as a port would
    # have worked them out by hand: each different tile as drawn (a tile, its bank and its turn) a
    # picture of 8x8, and the map those pictures, a big cell its tiles. So the console, the
    # interpreter and every build draw it as any background, and a tile that draws nothing is
    # left empty.
    #
    # WITH THE PACK LEFT OUT nothing of the slots is known here: not which tiles the map names, nor
    # which bank each is drawn from, nor one colour. So the background is declared by where its
    # map, tiles and colours are in the file the program is handed as it starts
    # (IR::StartFile::Background), and each backend that plays such a program works the cells out
    # as it starts, as they are worked out here. What the build must still know is true of it: its
    # size, and the names of its lists, every bank of the slot, since any of them may be drawn
    # from. A bank's colours are not known, so its list holds a marker for each
    # (#declare_bank_stand_in), and what a build holding them works out from them, the steps of a
    # `color_walk` among it, is made as the game starts.
    module PackBackgrounds
      private

      # The background +name+ from +tiles+, +map+ and +colors+ (DSL::PackSlot handles), +across+
      # cells to a row of the map, each cell +cell+ pixels square. +others+ are the background's
      # own settings, handed on.
      def declare_pack_background(name, tiles:, map:, colors:, across:, cell:, set_cells: nil, **others)
        refuse_set_cells_read_at_start!(name, set_cells)
        subject = "background :#{name}"
        refuse_tiles_not_from_slot!(tiles, subject)
        refuse_map_not_of_halves!(name, map)
        refuse_colors_not_whole_slot!(name, colors)
        words = pack_map_word_format!(name)
        refuse_bad_pack_background_shape!(name, map, across, cell, words)
        tiles_a_side = cell / Original::Slot::TILE_SIDE
        if pack_left_out?
          return declare_pack_background_read_at_start(name, tiles: tiles, map: map, colors: colors, across: across,
                                                             tiles_a_side: tiles_a_side, words: words, **others)
        end

        tile_places = pack_tile_places(tiles, subject)
        bank_lists = declare_pack_color_banks(colors, tiles.layout.format.colors, "#{subject}'s colors:")
        pictures = {}
        rows = pack_slot_values(map, :numbers, "#{subject}'s map:").each_slice(across).flat_map do |row|
          Array.new(tiles_a_side) do |down|
            row.flat_map do |word|
              Array.new(tiles_a_side) do |along|
                tile = words.cell_tile(word, along, down, tiles_a_side)
                pictures.fetch(tile) { pictures[tile] = pack_background_tile(name, tile, tile_places, bank_lists, pictures.length) }
              end
            end
          end
        end
        cells = declare_pack_cells_written_later(name, set_cells, words, tiles_a_side, pictures, bank_lists) do |tile, number|
          pack_background_tile(name, tile, tile_places, bank_lists, number)
        end
        drawn = pictures.values.compact
        refuse_pack_background_drawing_nothing!(name) if drawn.empty?
        tileset = :"background :#{name} tiles"
        tiles(tileset, drawn.to_h { |picture| [picture, picture] })
        # Which banks the map uses is in the player's copy, so the game may name any bank of the slot.
        background(name, tiles: tileset, map: rows, **others).allow_undrawn_lists(bank_lists).allow_set_cells(cells)
      end

      # THE CELLS THE BACKGROUND MAY BE WRITTEN LATER (`set_cells:`), each the original's own cell
      # number: a list of them, a Range (a run of tiles in one bank, turned one way), or a list of
      # both. The original writes words onto a screen by storing font cells in its map, and no
      # cell of the map names a font tile until then, so the pictures the map needs do not hold
      # them. Each told cell's tiles are made pictures here as the map's were and kept in +pictures+
      # with them, by tile as drawn, so a tile the map also draws is one picture. The block makes
      # the picture of a tile, given the tile and its number.
      #
      # A tile that draws nothing is left empty in the map, and `set_tile` has no key for an empty
      # cell. So a told tile that draws nothing is given a picture, see-through all over: the
      # font's space, which the original writes to take its words away again.
      #
      # Hands back a DSL::PackCells for the background's handle, or nil where none are told.
      def declare_pack_cells_written_later(name, set_cells, words, tiles_a_side, pictures, bank_lists)
        return nil if set_cells.nil?

        tiles_by_word = {}
        cells = DSL::PackCells.new(format: words, side: tiles_a_side, tiles_by_word: tiles_by_word)
        pack_cell_words!(name, set_cells).each do |word|
          tiles_by_word[cells.read_part(word)] ||= Array.new(tiles_a_side * tiles_a_side) do |at|
            tile = words.cell_tile(word, at % tiles_a_side, at / tiles_a_side, tiles_a_side)
            pictures[tile] = yield(tile, pictures.length) unless pictures.key?(tile)
            pictures[tile] || (pictures[[:blank, tile.bank]] ||= pack_background_blank_tile(name, tile.bank, bank_lists))
          end
        end
        cells
      end

      # The cell numbers +set_cells+ names, in the order given.
      def pack_cell_words!(name, set_cells)
        parts = set_cells.is_a?(Array) ? set_cells : [set_cells]
        told = parts.flat_map { |part| pack_cell_run?(part) ? part.to_a : [part] }
        return told if !told.empty? && told.all? { |word| word.is_a?(Integer) && word.between?(0, 0xFFFF) }

        raise ArgumentError, "background :#{name} was given set_cells: #{set_cells.inspect}. It takes the cell numbers that " \
                             "set_cell can write later, each a number of two bytes as the original's map holds them: a " \
                             "list like `[0xE500, 0xE501]`, or a range like `0xE500..0xE553`."
      end

      # Is +part+ of a `set_cells:` a run of cell numbers, written as a Range of them?
      def pack_cell_run?(part)
        part.is_a?(Range) && part.begin.is_a?(Integer) && part.end.is_a?(Integer) && part.begin >= 0 && part.end <= 0xFFFF
      end

      # A picture that draws nothing, for a told cell whose tile is see-through all over. It is
      # drawn from the list of +bank+ as the tile it stands for is, so it brings no colours of its own.
      def pack_background_blank_tile(name, bank, bank_lists)
        list = bank_lists.fetch(bank) do
          raise ArgumentError, "background :#{name} was told a cell drawn from bank #{bank} of colors, and its colors: " \
                               "slot holds #{bank_lists.length} banks. To fix this, give it a slot that holds every bank " \
                               "its cells use."
        end
        side = Original::Slot::TILE_SIDE
        picture = :"background :#{name} blank tile #{bank}"
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
      def declare_pack_background_read_at_start(name, tiles:, map:, colors:, across:, tiles_a_side:, words:, **others)
        subject = "background :#{name}"
        [[tiles, "tiles:"], [map, "map:"], [colors, "colors:"]].each { |slot, what| refuse_slot_from_elsewhere!(slot, "#{subject}'s #{what}") }
        bank_size = tiles.layout.format.colors
        first_tile = tiles.tile_index || 0
        where = IR::StartFile::Background.new(
          map_at: @pack_slot_starts.fetch(map.layout.name), cells: map.count, across: across, cell_tiles: tiles_a_side,
          number_format: map.layout.format, map_words: words,
          tiles_at: @pack_slot_starts.fetch(tiles.layout.name) + (first_tile * tiles.layout.item_bytes),
          tile_count: tiles.layout.count - first_tile, tile_format: tiles.layout.format,
          colors_at: @pack_slot_starts.fetch(colors.layout.name), bank_count: colors.count / bank_size, bank_size: bank_size,
          color_format: colors.layout.format,
          bank_names: Array.new(colors.count / bank_size) { |bank| :"#{colors.layout.name}_#{bank}" }
        )
        refuse_oversized_map_at_start!(name, where)
        stand_ins = where.bank_names.each_with_index.map { |list, bank| declare_bank_stand_in(name, list, bank, where, subject) }
        tileset = :"background :#{name} tiles"
        tiles(tileset, stand_ins.to_h { |picture| [picture, picture] })
        handle = background(name, tiles: tileset, map: Array.new(where.rows) { Array.new(where.columns, stand_ins.first) }, **others)
        @backgrounds.fetch(name).node.from_file = where
        # Which bank the map uses is in the file, so one list given alone is every bank's.
        handle.allow_one_list_for_every_bank
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

      # A CELL OF A BACKGROUND READ AS THE GAME STARTS CANNOT BE CHANGED WITH `set_tile`: the tile a
      # line names is a number among the background's tiles, and which tiles those are is in the
      # file. Checked once the whole program is declared, since a routine's lines are built last.
      def refuse_set_tile_read_at_start!
        return unless pack_left_out?

        read = @program.walk.select { |node| node.kind == :background && node.from_file }.map(&:name)
        changed = @program.walk.find { |node| node.kind == :set_tile && read.include?(node.name) }
        return unless changed

        raise ArgumentError, "background :#{changed.name} is told `set_tile`. Its tiles and map are read from the data " \
                             "pack as the game starts, so the build does not know which tiles it has. To fix this, " \
                             "build the game all-in-one."
      end

      def refuse_oversized_map_at_start!(name, where)
        return if where.tiles_drawn <= MOST_TILES_READ_AT_START

        raise ArgumentError, "background :#{name} has a map of #{where.columns} by #{where.rows} tiles, which is " \
                             "#{where.tiles_drawn} cells. This build reads its pack as the game starts, and such a " \
                             "background can have #{MOST_TILES_READ_AT_START} cells at most. To fix this, give it a " \
                             "smaller map, or build the game all-in-one."
      end

      # The picture of +tile+ (a Console::CellTile), drawn from the list of its bank. Nil for a tile
      # that draws nothing, left empty in the map.
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

      # The cells written later are worked out from what the slots hold, which a build that reads
      # its pack as the game starts does not have. With none told the background has no cells
      # `set_cell` can write, so no `set_cell` reaches a background read at start either.
      def refuse_set_cells_read_at_start!(name, set_cells)
        return if set_cells.nil? || !pack_left_out?

        raise ArgumentError, "background :#{name} was given set_cells:, and this build reads its pack as the game starts. " \
                             "A background's cells written later are not made that way yet. To fix this, build the game " \
                             "all-in-one."
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
