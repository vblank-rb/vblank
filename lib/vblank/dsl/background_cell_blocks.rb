# frozen_string_literal: true

module VBlank
  module DSL
    # Blocks of background cells
    #
    # A background changes a block of its cells in one line: filled with one tile (#fill_tiles),
    # with one of the cells a background from the data pack was told (#fill_cells), or put back
    # to the background's own map (#restore_cells). Every Background has these.
    #
    # ```ruby
    # speech.fill_cells left, top, 27, 1, EDGE          # the box's top edge
    # speech.fill_cells left + 1, top + 1, 25, 5, BLANK # and its inside
    # speech.restore_cells left - 1, top - 1, 29, 7     # the box closed: the picture under it again
    # ```
    #
    # A speech box opening, a menu's frame, a panel slid away: a console's own games write each
    # block with one command, which the gap between frames carries out cell after cell into video
    # memory. Written as two loops of `set_tile`, the same box is a test and a note for every
    # cell, and a few hundred of them are more than a pass has time for on a slow processor.
    #
    # Each block is `across` cells by `down` from `col` and `row`, counted as Background#set_tile
    # and Background#set_cell count them, and any of the four may be worked out as the game runs.
    # A cell off the map is left alone, and a block of no cells changes nothing. The cells change
    # where the line is, in order with every other change: a letter written into the box after it
    # is filled shows over it.
    #--
    # The block is one step of the program (IR::Nodes::SetTileBlock), and a console whose games
    # write blocks that way writes it that way; every other console plays the loops, which are the
    # step's meaning.
    #
    # Mixed into Background. Written as plain Ruby, not as game code: what it builds is the game's steps.
    #++
    module BackgroundCellBlocks
      # Fills a block of cells with one tile of the tileset.
      #
      # The tile is named as Background#set_tile names it: a key the map was written in, or a
      # number the game works out, counting through the keys from 0.
      #
      # ```ruby
      # room.fill_tiles 0, 0, 30, 2, "#"    # a wall two cells deep along the top
      # ```
      def fill_tiles(col, row, across, down, tile)
        refuse_unblocked_background!("fill_tiles")
        index = (@tile_index[tile] unless tile.is_a?(Value))
        raise ArgumentError, unknown_tile_message(tile) if index.nil? && !tile.is_a?(Value)
        return emit_cells_one_by_one(col, row, across, down) { |c, r| set_tile(c, r, tile) } unless index && block_written_whole?

        record_tile_block(col, row, across, down, tile: index) do |c, r|
          record(IR::Build.set_tile(@name, Value.node_for(c), Value.node_for(r), index))
        end
      end

      # Fills a block of cells with one of the cells a background from the data pack was told.
      #
      # The cell is named as Background#set_cell names it: the original's cell number, or its
      # place in the slot that told them.
      #
      # ```ruby
      # speech.fill_cells left + 1, top + 1, 25, 5, BLANK
      # ```
      def fill_cells(col, row, across, down, word)
        refuse_unblocked_background!("fill_cells")
        if @pack_cells.nil?
          raise ArgumentError,
                "background :#{@name} was not told any cells that fill_cells can write. To fix this, draw it from the " \
                "data pack and name the cells in `set_cells:`, or use fill_tiles with a key of its tileset."
        end

        cells = (@pack_cells.cell_block_tiles(@name, word) if block_written_whole? && @pack_cells.side == 1)
        return emit_cells_one_by_one(col, row, across, down) { |c, r| set_cell(c, r, word) } unless cells
        return fill_tiles(col, row, across, down, cells.tile) if cells.tile

        picks = cells.picks.map { |key| key && @tile_index.fetch(key) }
        kept = cells.picked_by.hidden_copy(:cell_block_pick)
        record_tile_block(col, row, across, down, picked_by: kept, tiles: picks, from: cells.from) do |c, r|
          record(IR::Build.set_tile_picked(@name, Value.node_for(c), Value.node_for(r), Value.node_for(kept), picks, from: cells.from))
        end
      end

      # Puts a block of cells back to the background's own map, as it was declared, so what a box
      # covered shows again.
      #
      # On a background from the data pack, the map is the original's. A background of several
      # maps, or one whose walls follow its tiles, cannot put a block back, and says so.
      #
      # ```ruby
      # speech.restore_cells left - 1, top - 1, 29, 7    # the box closed
      # ```
      def restore_cells(col, row, across, down)
        refuse_unblocked_background!("restore_cells")
        refuse_restore_unknown_map!
        map = @declaration.map
        side = @pack_cells&.side || 1
        # A cell of a background from the pack may be several tiles each way; the block is in tiles.
        col, row, across, down = [col, row, across, down].map { |number| side == 1 ? number : number * side }
        return record_restored_block_from_file(col, row, across, down) if @declaration.from_file

        columns = map.first.length
        uses = map.flatten.compact.uniq
        emptied = map.flatten.include?(nil)
        place = @builder.hidden_variable(:cell_block_place)
        held = (true if @held)
        body = lambda do |c, r|
          # A cell of the map that names no tile is emptied, then given the map's tile where it has one.
          if emptied
            node = record(IR::Build.set_tile(@name, Value.node_for(c).copy, Value.node_for(r).copy, nil, held: held))
            @builder.note_held_tile_change(node) if held
          end
          place.store!(restore_table[(r * columns) + c])
          node = record(IR::Build.set_tile_picked(@name, Value.node_for(c).copy, Value.node_for(r).copy, Value.node_for(place), uses,
                                                  held: held))
          @builder.note_held_tile_change(node) if held
        end
        return record_tile_block(col, row, across, down, restore: true, also_zeroed: [place.name], &body) unless held

        emit_cells_one_by_one(col, row, across, down, &body)
        place.store!(0)
        self
      end

      private

      # The map as declared, a table in the cartridge that `restore_cells` reads a cell of at a time:
      # for each cell, row by row, its tile's place among the tiles the map uses, or -1 for a cell
      # that names none. So a cell put back picks among the map's own tiles, not every cell of it.
      def restore_table
        @restore_table ||= begin
          cells = @declaration.map.flatten
          place_of = cells.compact.uniq.each_with_index.to_h
          @builder.table(:"__restore_#{@name}", cells.map { |tile| tile ? place_of.fetch(tile) : -1 }, width: :half)
        end
      end

      # A block put back on a background read from the data pack as the game starts has no children:
      # its map is the file's, which the build does not hold, so it cannot be written a cell at a
      # time from a table. Only the interpreter and the builds for a computer leave a pack out, and
      # each puts the block back from the map it read (Reference#exec_set_tile_block, the runtimes'
      # rg_background_restore_cells).
      def record_restored_block_from_file(col, row, across, down)
        col, row, across, down = [col, row, across, down].map { |number| keep_number_readable(number) }
        record(IR::Build.set_tile_block(@name, Value.node_for(col), Value.node_for(row), Value.node_for(across),
                                        Value.node_for(down), restore: true))
        self
      end

      # The block as one step, whose children are the same cells a cell at a time: two counted loops
      # over +across+ and +down+ handing +body+ each cell's column and row, then every variable the
      # loops changed (theirs, and +also_zeroed+) set back to nought, so a console that writes the
      # block its own way, and never runs them, holds the same numbers.
      def record_tile_block(col, row, across, down, tile: nil, picked_by: nil, tiles: nil, from: 0, restore: nil,
                            also_zeroed: [], &body)
        col, row, across, down = [col, row, across, down].map { |number| keep_number_readable(number) }
        node = IR::Build.set_tile_block(@name, Value.node_for(col), Value.node_for(row), Value.node_for(across), Value.node_for(down),
                                    tile: tile, picked_by: picked_by && Value.node_for(picked_by), tiles: tiles, from: from,
                                    restore: restore)
        @builder.record_container(node) do
          counters = emit_block_loops(col, row, across, down, &body)
          (counters + also_zeroed).uniq.each { |name| record(IR::Build.set(name, 0)) }
        end
        self
      end

      # The block as two counted loops and nothing else, for a background whose cells a block cannot
      # be written to as one step: each cell is written as the line in the block writes it.
      def emit_cells_one_by_one(col, row, across, down, &body)
        col, row, across, down = [col, row, across, down].map { |number| keep_number_readable(number) }
        emit_block_loops(col, row, across, down, &body)
        self
      end

      # Two counted loops, rows then the cells of each, handing the block each cell's column and row
      # as Values. Hands back the loops' own variables.
      def emit_block_loops(col, row, across, down)
        counters = []
        @builder.repeat(down) do |r|
          counters << r.name
          @builder.repeat(across) do |c|
            counters << c.name
            yield c + col, r + row
          end
        end
        counters
      end

      # +number+ as something a block can read as often as it likes: a number written in the game,
      # a variable, or anything else worked out once into a variable of its own.
      def keep_number_readable(number)
        return number if Value.fixed_number(number)
        return number if number.is_a?(Value) && number.name

        Value.new(@builder, Value.node_for(number)).hidden_copy(:cell_block)
      end

      # A block as one step is the cells and nothing more: not on a background whose changes wait
      # for the end of the pass (held), nor one whose walls go with its tiles.
      def block_written_whole? = !@held && !walls_follow_tiles?

      # What `set_tile` refuses, a block refuses too.
      def refuse_unblocked_background!(verb)
        refuse_on_bitmap_screen!(verb, instead: "Draw over the spot with `blit`")
        if @walks_areas
          raise ArgumentError,
                "background :#{@name} walks between areas, so a tile name can be in more than one area. " \
                "#{verb} cannot change a block of it. To fix this, give each look of the room a map of its own " \
                "and use show_map."
        end
        refuse_block_on_streamed_map!(verb)
      end

      # Restoring needs the map as the build knows it. A background of several maps shows whichever
      # the game last handed it; one whose walls go with its tiles would need each cell's wall put
      # back too; and one read from the data pack as the game starts, declared `held: true`, would
      # hold cells the build cannot name, since its map is the file's.
      def refuse_restore_unknown_map!
        problem =
          if @map_names.length > 1
            "was declared with several maps, and restore_cells puts back the cells of one map"
          elsif walls_follow_tiles?
            "has walls that follow its tiles, and restore_cells does not put back walls"
          elsif @declaration.from_file && @held
            "is read from the data pack as the game starts and holds its cells (`held: true`), so the build " \
              "cannot hold the cells of its map"
          end
        return unless problem

        raise ArgumentError, "background :#{@name} #{problem}. To fix this, write the cells back with set_tile or set_cell."
      end
    end
  end
end
