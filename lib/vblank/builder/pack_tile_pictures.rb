# frozen_string_literal: true

module VBlank
  class Builder
    # A TILE OF A BACKGROUND FROM THE DATA PACK TAKING TURNS THROUGH PICTURES OF THE PACK:
    #
    #   belt = tile_pictures :belt, tiles: { pack[:video].tile(0xF3) => pack[:belt].tiles(0, across: 16),
    #                                        pack[:video].tile(0xF4) => pack[:belt].tiles(16, across: 16) }
    #   background :lair, tiles: pack[:video], map: pack[:lair_map], colors: pack[:palette], across: 64
    #   belt.show step
    #
    # A retail game makes a conveyor crawl or water lap by writing new pixels into a tile of video
    # memory while the map stays still: every cell naming the tile changes at once, each in its own
    # bank of colours and turned its own way. Here a key is that tile, named by its place in a slot
    # of tiles, and its value the pictures it goes through, tiles of the pack too (one handle on a
    # run of them, or a list of single tiles), which the port's unpacking can make.
    #
    # It stands on `tile_pictures`' runs (TilePictures#declare_tile_picture_run), so it works on
    # every console and build that a background from the pack does. A run has one list of colours
    # and its tiles one turn each, while the cells naming a tile can be of several banks and
    # turns. So each background drawn from the slot gets, for each bank its cells name the tile
    # in (the map's, and those `set_cells:` names, which `set_cell` writes later), a run of the
    # tile turned each way they name it (#declare_moving_pack_tiles), and the
    # group's `show` copies the picture into every run (#emit_pack_tile_picture_copies). Those
    # runs are made as a background is declared, so the group is declared before any background
    # drawn from its tiles' slot.
    #
    # WITH THE PACK LEFT OUT the map is not known as the game is built, nor which banks and turns
    # name the tile. So each background has a run for every bank of its colours, each holding the
    # tile turned all four ways, and the cells are pointed at them as the game starts
    # (IR::StartFile::Background#moving); a told cell naming a key is written as the run's tile
    # for its bank and turn (PackBackgrounds#pack_run_tile_read_at_start). The pictures are read
    # from the file as it starts too, in the bytes a run copies (IR::StartFile::PaintedTiles).
    module PackTilePictures
      # The four ways a tile of such a background is turned, in the order a run read at start
      # holds them; a tile's place in it is IR::StartFile::MovingTile#turn_of.
      TURNS = IR::StartFile::MovingTile::TURNS

      # A group as the builder keeps it: +keys+ the tiles (each [slot name, tile in the slot]),
      # +pictures+ each key's picture handles, +shown+ the number showing, and +parts+ every run
      # made for it so far (TilePictures::TilePictureRun), which grows as backgrounds are declared.
      PackTileGroup = Data.define(:name, :keys, :pictures, :shown, :parts, :fast)

      private

      # The routine `show` calls on a frame the picture changes: a copy into every run of the group.
      def emit_pack_tile_picture_copies(group)
        group.parts.each do |part|
          part.list.copy_from(part.held, at: Build.binop(:*, group.shown.node, Build.int(part.bytes_shown)), count: part.bytes_shown)
          part.run.changed
        end
      end

      # Whether `tile_pictures` was given tiles of the data pack.
      def pack_tile_pictures?(tiles) = tiles.is_a?(Hash) && tiles.each_key.any?(DSL::PackSlot)

      def declare_pack_tile_pictures(name, tiles, colors, fast:)
        refuse_colors_for_pack_tile_pictures!(name, colors)
        keys = tiles.keys.map { |key| pack_tile_picture_key!(name, key) }
        pictures = tiles.values.map { |handle| pack_tile_picture_handles!(name, handle) }
        refuse_bad_pack_tile_pictures!(name, keys, pictures)
        shown = var(Messages::MadeNames.make(:tile_pictures_part, group: name, part: :picture), 0)
        group = PackTileGroup.new(name: name, keys: keys.map { |key| [key.layout.name, key.tile_index] }, pictures: pictures,
                                  shown: shown, parts: [], fast: fast)
        (@pack_tile_groups ||= []) << group
        routine = Messages::MadeNames.make(:tile_pictures_part, group: name, part: :show)
        # Built last, once every background drawn from the tiles has made its runs.
        func(routine) { emit_pack_tile_picture_copies(group) }
        build_last(routine)
        DSL::PackTilePictureGroup.new(self, name: name, pictures: pictures.first.length, shown: shown, routine: routine)
      end

      # A key: one tile of a slot of tiles, no background yet drawn from that slot.
      def pack_tile_picture_key!(name, key)
        unless key.is_a?(DSL::PackSlot) && key.shape == :tiles && key.one_tile? && key.count == 1
          raise ArgumentError, "tile_pictures :#{name} was given a key that is not one tile. Each tile of a group from the " \
                               "data pack is one tile of a slot of tiles, like `pack[:video].tile(5)`."
        end
        refuse_slot_from_elsewhere!(key, "tile_pictures :#{name}")
        taken = (@pack_tile_groups || []).find { |group| group.keys.include?([key.layout.name, key.tile_index]) }
        if taken
          raise ArgumentError, "tile_pictures :#{name} names tile #{key.tile_index} of slot :#{key.layout.name}, and " \
                               "tile_pictures :#{taken.name} names it already. A tile takes turns in one group. To fix " \
                               "this, put the tile in one group only."
        end
        return key unless @pack_background_slots&.include?(key.layout.name)

        raise ArgumentError, "tile_pictures :#{name} names a tile of slot :#{key.layout.name}, and a background drawn from " \
                             "that slot is declared already. To fix this, declare tile_pictures before the background."
      end

      # A tile's pictures, each a handle on one tile: a handle on several tiles of a slot (each tile
      # a picture, in order), a whole slot, or a list of single tiles.
      def pack_tile_picture_handles!(name, handle)
        handles = if handle.is_a?(DSL::PackSlot) && handle.shape == :tiles
                    first = handle.tile_index || 0
                    Array.new(handle.count) { |at| handle.with(tile_index: first + at, across: 1, down: 1) }
                  else
                    handle
                  end
        unless handles.is_a?(Array) && !handles.empty? &&
               handles.all? { |each| each.is_a?(DSL::PackSlot) && each.shape == :tiles && each.one_tile? && each.count == 1 }
          raise ArgumentError, "tile_pictures :#{name} needs the pictures of each tile from the data pack: tiles of a slot, " \
                               "like `pack[:pictures].tiles(0, across: 16)`, or a list of single tiles."
        end
        handles.each { |each| refuse_slot_from_elsewhere!(each, "tile_pictures :#{name}") }
        handles
      end

      def refuse_colors_for_pack_tile_pictures!(name, colors)
        return if colors.nil?

        raise ArgumentError, "tile_pictures :#{name} was given colors:, and its tiles are from the data pack. Each cell " \
                             "draws them in the bank of colors it names. To fix this, remove colors:."
      end

      def refuse_bad_pack_tile_pictures!(name, keys, pictures)
        unless pictures.map(&:length).uniq.one?
          raise ArgumentError, "tile_pictures :#{name} gives its tiles different numbers of pictures. `show` picks the " \
                               "picture of the whole group, so each tile needs the same number. To fix this, make the lists " \
                               "the same length, or put the tiles in groups of their own."
        end
        formats = [*keys, *pictures.flatten].map { |handle| handle.layout.format }.uniq
        return if formats.one? && formats.first.colors <= Images::PICTURE_COLORS

        raise ArgumentError, "tile_pictures :#{name} has tiles and pictures of different kinds, or tiles of more than " \
                             "#{Images::PICTURE_COLORS} colors. Each picture takes the place of the pixels of its tile. " \
                             "So every tile and picture must be of one kind, with #{Images::PICTURE_COLORS} colors or fewer."
      end

      # The groups whose tiles a background drawn from +tiles+ (a slot, or its tiles from one on)
      # draws, by the map's number for the tile: each [group, key's place in the group].
      def moving_pack_tiles_of(tiles)
        first = tiles.tile_index || 0
        (@pack_tile_groups || []).each_with_object({}) do |group, found|
          group.keys.each_with_index do |(slot, tile), key|
            found[tile - first] = [group, key] if slot == tiles.layout.name && tile >= first
          end
        end
      end

      # A background drawn from +tiles+' slot is noted, so a group declared after it is refused.
      def record_pack_background_slot(tiles) = (@pack_background_slots ||= Set.new) << tiles.layout.name

      # THE RUNS OF A BACKGROUND BUILT ALL-IN-ONE: for each group and each bank +cells+ (the
      # Console::CellTile each cell names, that +moving+ says take turns) name, a run of each turn
      # of each key they name it in. Hands back the name of the run's tile for each CellTile.
      def declare_moving_pack_tiles(name, cells, moving, bank_lists)
        cells.group_by { |tile| [moving.fetch(tile.tile).first, tile.bank] }.each_with_object({}) do |((group, bank), drawn), names|
          list = moving_pack_bank_list(name, bank, bank_lists)
          places = moving_pack_picture_places(group)
          bytes = (0...group.pictures.first.length).flat_map do |picture|
            drawn.flat_map { |tile| moving_pack_tile_bytes(tile, places.fetch(moving.fetch(tile.tile).last).fetch(picture)) }
          end
          names.merge!(declare_moving_pack_run(group, drawn, list, bytes, Original::Slot::TILE_SIDE))
        end
      end

      # THE RUNS OF A BACKGROUND OF 16x16 CELLS BUILT ALL-IN-ONE (PackBackgrounds#big_pack_cells?):
      # each cell of +cells+ (the four quarters of each, Console::CellTile, a quarter or more of
      # which +moving+ says take turns, all in one group) is a 16x16 picture of a run, for each group
      # and each bank: its turning quarters the group's picture, the rest the slot's tile, each
      # turned as the cell turns it. So a `show` copies the whole cell, four times the bytes of a
      # tile, and the map names one tile for it, as a console's own game keeps such a screen.
      # Hands back the name of the run's tile for each cell's quarters.
      def declare_moving_pack_big_cells(shape, cells, moving)
        by_run = cells.group_by do |quarters|
          [moving.fetch(quarters.find { |tile| moving.key?(tile.tile) }.tile).first, quarters.first.bank]
        end
        by_run.each_with_object({}) do |((group, bank), drawn), names|
          list = moving_pack_bank_list(shape.name, bank, shape.bank_lists)
          places = moving_pack_picture_places(group)
          bytes = (0...group.pictures.first.length).flat_map do |picture|
            drawn.flat_map do |quarters|
              quarters.flat_map do |tile|
                _, key_at = moving[tile.tile]
                tile_places = if key_at
                                places.fetch(key_at).fetch(picture)
                              else
                                pack_tile_at(shape.tile_places, tile.tile, "background :#{shape.name}")
                              end
                moving_pack_tile_bytes(tile, tile_places)
              end
            end
          end
          names.merge!(declare_moving_pack_run(group, drawn, list, bytes, shape.tiles_a_side * Original::Slot::TILE_SIDE))
        end
      end

      # The list of colours of +bank+ for a run of background +name+, or a friendly error.
      def moving_pack_bank_list(name, bank, bank_lists)
        bank_lists.fetch(bank) do
          raise ArgumentError, "background :#{name} has a cell drawn from bank #{bank} of colors, and its colors: slot holds " \
                               "#{bank_lists.length} banks. To fix this, give it a slot that holds every bank its map and " \
                               "its set_cells: use."
        end
      end

      # Each key's pictures of +group+, each a list of its 64 places row by row.
      def moving_pack_picture_places(group)
        group.pictures.map { |handles| handles.map { |handle| pack_tile_places(handle, "tile_pictures :#{group.name}").first } }
      end

      # The painted bytes of the 8x8 +places+ turned as +tile+ (a Console::CellTile) turns them.
      def moving_pack_tile_bytes(tile, places)
        rows = places.each_slice(Original::Slot::TILE_SIDE).to_a
        painted_tile_bytes(turned_rows(rows, mirrored: tile.mirrored, upside_down: tile.upside_down).flatten)
      end

      # A run of +group+ holding a +side+ tile for each of +drawn+, drawn in +list+, its pictures
      # +bytes+; one for each background and bank. Hands back the name of the run's tile for each.
      def declare_moving_pack_run(group, drawn, list, bytes, side)
        run = :"#{group.name}_run_#{group.parts.length}"
        group.parts << declare_tile_picture_run(run, count: drawn.length, colors: list, side: side, bytes: bytes, fast: group.fast)
        drawn.each_with_index.to_h { |cell, at| [cell, Messages::MadeNames.make(:tile_run_tile, run: run, number: at + 1)] }
      end

      # THE RUNS OF A BACKGROUND READ AS THE GAME STARTS (+where+, an IR::StartFile::Background):
      # for each group and each bank of the slot, a run of each key turned each of the four ways,
      # its pictures read from the file. Hands back the run's tiles, in order, and +where+ told
      # which cells to point at them, +first+ being where they start among the background's tiles.
      def declare_pack_tile_runs_at_start(name, moving, where, first)
        tiles = []
        groups = moving.values.map(&:first).uniq
        moving_tiles = groups.flat_map do |group|
          keys = group.keys.length
          start = first + tiles.length
          where.bank_names.each_with_index do |list, bank|
            run = :"#{group.name}_run_#{group.parts.length}" # one for each background and bank
            held = declare_painted_pictures_read_at_start(run, group)
            group.parts << declare_tile_picture_run(run, count: keys * TURNS.length, colors: list, side: Original::Slot::TILE_SIDE,
                                                         bytes: nil, fast: group.fast, held: held)
            tiles.concat(Array.new(keys * TURNS.length) { |at| Messages::MadeNames.make(:tile_run_tile, run: run, number: at + 1) })
          end
          moving.filter_map do |tile, (each, key)|
            IR::StartFile::MovingTile.new(tile: tile, first: start + (key * TURNS.length), bank_step: keys * TURNS.length) if each == group
          end
        end
        [tiles, where.with(moving: moving_tiles.freeze)]
      end

      # The table a run read at start copies its pictures from: each picture's tiles, each key
      # turned the four ways, as a run's bytes keep them, read from the file as the game starts.
      def declare_painted_pictures_read_at_start(run, group)
        format = group.pictures.first.first.layout.format
        read = (0...group.pictures.first.length).flat_map do |picture|
          group.pictures.flat_map do |handles|
            handle = handles.fetch(picture)
            at = @pack_slot_starts.fetch(handle.layout.name) + (handle.tile_index * handle.layout.item_bytes)
            TURNS.map { |turns| IR::StartFile::PaintedTile.new(at: at, turns: turns) }
          end
        end
        name = Messages::MadeNames.make(:tile_pictures_part, group: run, part: :pictures)
        node = Build.table(name, Array.new(read.length * TilePictures::TILE_BYTES, 0), width: :byte, signed: false)
        node.painted_from_file = IR::StartFile::PaintedTiles.new(tile_format: format, tiles: read.freeze)
        record(node)
        DSL::Table.new(self, name, read.length * TilePictures::TILE_BYTES, width: :byte)
      end

      # A tile of 256 colours picks from the whole table and has no bank, and a run's tile has
      # sixteen places at most.
      def refuse_moving_table_tiles!(name, tiles)
        return unless drawn_from_whole_table?(tiles)

        raise ArgumentError, "background :#{name} has tiles of #{tiles.layout.format.colors} colors, and tile_pictures names " \
                             "one of them. A tile that takes turns through pictures has #{Images::PICTURE_COLORS} colors or " \
                             "fewer. To fix this, leave this background's tiles out of tile_pictures."
      end

      # A tile's places, row by row, as a run's list keeps them: two a byte, the left one in the low
      # four bits (TileRuns).
      def painted_tile_bytes(places) = places.each_slice(2).map { |near, far| near | (far << 4) }
    end
  end
end
