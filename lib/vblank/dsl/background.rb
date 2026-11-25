# frozen_string_literal: true

module VBlank
  module DSL
    # A tiled background
    #
    # `background :world, ...` hands one back. It is a map of tiles that the console draws for
    # you, and the screen is a window onto it. Move the window with #scroll_by and #scroll_to,
    # change one cell with #set_tile, put up a whole other map with #show_map, and draw it in
    # other colours with #draw_with.
    #
    # ```ruby
    # world = background :world, tiles: :terrain, map: BIG_MAP
    # game_loop do
    #   wait_vblank
    #   world.scroll_by 2, 0 if held(:right)   # slide the view right
    # end
    # ```
    #
    # The map wraps around: scroll past an edge and it starts again from the other side, so a
    # map only needs to be as big as the pattern you want to repeat.
    #
    # You set where the window sits, in pixels. You never write a scroll register or think about
    # where the map lives in video memory: the framework moves the window in the gap between
    # frames, so the picture never tears.
    class Background
      include BackgroundCellBlocks

      Build = IR::Build

      # Built by the `background` verb, which allocates the hidden offset variables the
      # window's top-left corner is tracked in.
      #
      # @param builder [Builder] the build these operations record into
      # @param name [Symbol] the background this handle scrolls
      # @param scroll_x [Symbol] the variable holding the window's left edge (in pixels)
      # @param scroll_y [Symbol] the variable holding the window's top edge (in pixels)
      # @param walls [Array<Array(Integer,Integer,Integer,Integer)>] the solid-tile
      #   rectangles [x, y, w, h] in pixels, if the tileset marked any tiles `solid:`
      # @param cells [Array(Integer, Integer)] how many cells across and down the map is
      # @param tile_index [Hash] each name the map was written in (a tileset character, or
      #   a number from an imported sheet) to the tile it means — what `set_tile` reads
      # @param bitmap [Boolean] declared under `screen :bitmap`, where a background is
      #   stamped into the one picture rather than drawn by tile hardware
      # @param map_names [Array<Object>] the maps this background was declared with, in
      #   order — what `show_map` names. One entry (the background's own name) for a
      #   background declared with a single map, which can never be handed another.
      # @param node [IR::Node] the statement that declared it, so a `rotate!`/`scale` written
      #   on the same line can tell that it is still part of declaring this background
      #   rather than something the frame does to it (see {#on_declaration_line?})
      # @param tile_pictures [Array<Symbol>] the pictures its tileset draws, which is what
      #   another list of colours is matched against — see {#draw_with}
      def initialize(builder, name:, scroll_x:, scroll_y:, walls: [],
                     cells: [0, 0], tile_index: {}, bitmap: false, map_names: nil,
                     solid_cells: [], tile_size: [8, 8], node: nil, tile_pictures: [], walks_areas: false,
                     streams: false, solid_tiles: nil, held: false, area_tiles: nil)
        @builder = builder
        @held = held # its set_tile changes wait for the frame boundary (Builder::Tiled#background)
        @name = name
        @tile_pictures = tile_pictures
        @declaration_tail = node
        @declaration = node # the background statement itself, whatever is written on its line after it
        @scroll_x = scroll_x
        @scroll_y = scroll_y
        @walls = walls
        @solid_cells = solid_cells
        # The tile numbers that are walls, or nil where the walls were written apart (`walls:`)
        # and a tile marks nothing about them.
        @solid_tiles = solid_tiles
        @tile_size = tile_size
        @cells = cells
        @tile_index = tile_index
        @bitmap = bitmap
        @walks_areas = walks_areas # its maps are in several areas, each drawn from its own tiles
        @area_tiles = area_tiles # each area's keys and maps (AreaTiles), for one that walks between areas
        @streams = streams # its maps are brought into view a strip at a time (see IR::TileMap.streams?)
        @map_names = map_names || [name]
        @lists_allowed_undrawn = [] # see #allow_undrawn_lists
        @pack_cells = nil # see #allow_set_cells
      end

      # Lists `draw_with` takes though no tile may be drawn from them. Which lists a background's
      # tiles are drawn from is, as a rule, the game's own doing, so naming one that none is drawn
      # from is a name spelled wrong, and refused. A background from the data pack differs: which
      # banks of colours its map uses is in the player's copy of the original, which the game
      # cannot read as it is written. So its game names every bank the screen fades, and the banks
      # this map does not use are left out: nothing is drawn from them, so nothing is recoloured.
      #
      # Called by Builder::PackBackgrounds as it declares the background, with every bank of its slot.
      def allow_undrawn_lists(names) # :nodoc:
        @lists_allowed_undrawn = names
        self
      end

      # One list given alone (`draw_with :dusk`, `draw_with walk, showing: step`) draws every list
      # of the layer. A layer drawn from several lists is, as a rule, told which list each is drawn
      # with, by name. A background from the data pack whose pack is read as the game starts has
      # a list for every bank of its slot, since which banks its map uses is in the file. A game
      # whose screen uses one bank gives one list and names none, which is right where the build
      # holds the map and sees the one bank; here the same line draws every bank with that list,
      # so the bank the map uses shows it, and the two builds show one picture.
      #
      # Called by Builder::PackBackgrounds as it declares such a background.
      def allow_one_list_for_every_bank # :nodoc:
        @one_list_for_every_bank = true
        self
      end

      # The cells `set_cell` MAY WRITE, each as the original's own cell number (a PackCells), or nil
      # for none.
      #
      # Called by Builder::PackBackgrounds as it declares the background, with the cells its
      # `set_cells:` named.
      def allow_set_cells(cells) # :nodoc:
        @pack_cells = cells
        self
      end

      # The cells `set_cell` may write in each area of a background from the data pack that walks
      # between areas: a PackCells for each area, in the order of its maps (one map an area), or nil
      # for an area told none. Each area's pictures are its own, so a picture names one tile of
      # +tiles+ (the background's tiles, every area's after the last) and `set_cell` writes the tile
      # of the area the game has asked to show.
      #
      # Called by Builder::PackBackgrounds#declare_pack_background_areas.
      def allow_set_cells_by_area(cells_by_area, tiles) # :nodoc:
        @area_pack_cells = cells_by_area
        @tile_index = tiles.each_with_index.to_h
        self
      end

      # The name the background was declared with.
      attr_reader :name

      # Where this background keeps its state, for reading it back (IR::BackgroundReading).
      def reading # :nodoc:
        IR::BackgroundReading.new(name: @name, scroll_x: @scroll_x, scroll_y: @scroll_y,
                                  shown_map: (shown_map_var unless @map_names.one?), maps: @map_names)
      end

      # Puts a different tile in one cell of the map, while the game runs.
      #
      # ```ruby
      # room.set_tile 4, 7, "."    # the door is open now
      # room.set_tile 4, 7, "#"    # and shut again
      # ```
      #
      # A door that opens, a pot that breaks, a wall a bomb takes out, a block the player
      # pushes: each of those is one tile changing. Without this, each would have to be a
      # sprite instead, out of a budget a game would rather spend on things that move.
      #
      # `col` and `row` are cells, not pixels, and either may be a number the game works out.
      # The tile is named the way the map was written: one of the tileset's own characters, or a
      # number from an imported sheet. A number the game works out picks a key by its place
      # among the tileset's keys, counting from 0. A cell outside the map is left alone, so a
      # place the game worked out can be off the edge with no test around it.
      #
      # The same call works on every kind of background, with the tile named the way that
      # background's map names its cells:
      #
      # ```ruby
      # rooms.set_tile 10, 4, "o"    # walks between areas: a key of the tileset of the area showing
      # rooms.set_tile 10, 4, 0      # from the data pack: a cell number its set_cells: named
      # ```
      #
      # The change stays as the view scrolls the cell out and back in, and lasts until #show_map
      # puts that map up again. If the background walls in movers with `solid:` tiles, the
      # cell's wall changes with its tile. On a background declared `held: true` the change
      # waits, with every other change the pass makes, and they all show together on the next
      # frame.
      #
      # * `now:` - on a status bar, writes the cell at once rather than in the gap between
      #   frames (StatusBar#set_tile).
      #--
      # A console that brings a big map into view a strip at a time keeps the map showing in work
      # memory once the game changes it, as its own games keep a room's cells, and brings each
      # strip in from there. Held changes are gathered by Builder#finalize_held_tiles.
      #++
      def set_tile(col, row, tile, now: nil)
        refuse_on_bitmap_screen!("set_tile", instead: "Draw over the spot with `blit`")
        return set_cell(col, row, tile, now: now ? true : false) if (@pack_cells || @area_pack_cells) && !@tile_index.key?(tile)
        return set_tile_in_area_showing(col, row, tile, now) if @walks_areas && @area_tiles && !@area_pack_cells
        return set_tile_picked_by(col, row, tile, now) if tile.is_a?(Value)

        index = @tile_index[tile]
        raise ArgumentError, unknown_tile_message(tile) if index.nil?

        write_tile_number(col, row, index, now)
        record_wall_change(col, row, index)
        self
      end

      # Which of a background's tiles each key of one area's tileset names (+tile_index+), and the
      # numbers of the area's maps (+maps+, a Range), for a background that walks between areas.
      AreaTiles = Data.define(:tile_index, :maps) # :nodoc:

      # #set_tile on a background that walks between areas: the key names a tile of each area whose
      # tileset has it, and the cell takes the tile of the area showing, one test of the map showing
      # for each area that names another tile. An area whose tileset lacks the key leaves the cell
      # alone. A key no area has is refused.
      def set_tile_in_area_showing(col, row, tile, now) # :nodoc:
        if tile.is_a?(Value)
          raise ArgumentError, "background :#{@name} walks between areas, and set_tile was given a number the game works " \
                               "out. Each area names its tiles by its own keys. To fix this, give set_tile a key of the " \
                               "tileset, written in the program."
        end
        held = @area_tiles.select { |area| area.tile_index.key?(tile) }
        raise ArgumentError, unknown_tile_message(tile, keys: @area_tiles.flat_map { |area| area.tile_index.keys }.uniq) if held.empty?

        by_number = held.group_by { |area| area.tile_index.fetch(tile) }
        if by_number.one? && held.length == @area_tiles.length
          write_tile_number(col, row, by_number.keys.first, now)
          return self
        end

        by_number.each do |index, areas|
          areas.each { |area| with_map_showing_in(area.maps) { write_tile_number(col, row, index, now) } }
        end
        self
      end

      # The block's lines run only while the map showing is one of +maps+ (a Range of map numbers).
      def with_map_showing_in(maps) # :nodoc:
        return yield if map_count == 1 # the only map is always the one showing

        tests = if maps.one?
                  [PlainRuby::Steps::GameTest.new(showing == maps.first)]
                else
                  [PlainRuby::Steps::GameTest.new(showing >= maps.first), PlainRuby::Steps::GameTest.new(showing < maps.end)]
                end
        tests.each(&:open_yes_side)
        yield
        tests.reverse_each { |test| test.close_side(nil) }
      end

      # One cell given the background's tile number +index+, held for the end of the pass on a
      # background declared `held: true`.
      def write_tile_number(col, row, index, now) # :nodoc:
        node = record(Build.set_tile(@name, Value.node_for(col), Value.node_for(row), index, now: now,
                                                                                            held: (true if @held)))
        @builder.note_held_tile_change(node) if @held
        node
      end

      # A tile picked by a number the game works out, counting from nought through the tileset's
      # keys in the order they were written, which a number that names no key leaves the cell alone
      # for. It is one step of the game, picking from the list of every key (#set_tile_picked), as
      # PackCells writes a worked-out `set_cell`: a console that keeps the keys' cells as a table
      # reads the cell from it by the number, the way its own games write a letter, so a letter costs
      # the same however many tiles there are. A number worked out is kept while the line writes the
      # cell, in the variable every such line of the routine shares (Value#step_copy); one read the
      # same each time is not (#read_again_alike?).
      #
      # A background whose walls follow its tiles keeps the tests a game would write by hand, halving
      # the keys each time, since the wall goes with the tile: six tests for 43 tiles, and one
      # `set_tile` for each of them in the cartridge.
      def set_tile_picked_by(col, row, number, now) # :nodoc:
        keys = @tile_index.reject { |_, index| index.nil? }.keys
        unless walls_follow_tiles?
          kept = read_again_alike?(number.node) ? number : number.step_copy(:cell_number)
          return set_tile_picked(col, row, kept, keys, now: now)
        end

        in_range = PlainRuby::Steps::GameTest.new(number >= 0)
        in_range.open_yes_side
        below_end = PlainRuby::Steps::GameTest.new(number < keys.length)
        below_end.open_yes_side
        set_tile_between(col, row, number, keys, now)
        below_end.close_side(nil)
        in_range.close_side(nil)
        self
      end

      # Whether +node+ reads the same number every time it is read in one step, for about the cost
      # of the read: a number, a variable, an item of a table at a place written in the program, or
      # a sum or difference of those. Such a number needs no variable to keep it in, and a build
      # that knows it as the cartridge is built (a table the data pack fills, read with the game)
      # still sees it, so the cell is that one tile (IR::PickedTile.written).
      def read_again_alike?(node) # :nodoc:
        case node.kind
        when :int, :var_ref then true
        when :table_get then node.index.kind == :int
        when :binop then %i[+ -].include?(node.op) && read_again_alike?(node.lhs) && read_again_alike?(node.rhs)
        else false
        end
      end

      def set_tile_between(col, row, number, keys, now, first: 0) # :nodoc:
        return set_tile(col, row, keys.first, now: now) if keys.one?

        lower, upper = keys.each_slice(keys.length.ceildiv(2)).to_a
        which = PlainRuby::Steps::GameTest.new(number < first + lower.length)
        which.open_yes_side
        set_tile_between(col, row, number, lower, now, first: first)
        which.close_side(nil)
        which.open_no_side
        set_tile_between(col, row, number, upper, now, first: first + lower.length)
        which.close_side(nil)
      end

      # A tile picked from a list of keys by a number the game works out: +keys+ are the tileset's
      # keys the numbers from +from+ up stand for, nil for a number that stands for none, which
      # leaves the cell alone, as does a number before +from+ or past the last key. It is one step
      # of the program however many keys there are (IR::Nodes::SetTile#picked_by): a console's
      # build keeps the keys' cells as a table and indexes it, where it can.
      #
      # The walls do not follow such a cell, so a background whose walls follow its tiles
      # (#walls_follow_tiles?) is not written this way.
      #
      # Called by PackCells, for a cell written as the original's own cell number. +now+ is #set_tile's.
      def set_tile_picked(col, row, number, keys, from: 0, now: nil) # :nodoc:
        refuse_on_bitmap_screen!("set_cell", instead: "Draw over the spot with `blit`")
        tiles = keys.map { |key| key && @tile_index.fetch(key) }
        node = record(Build.set_tile_picked(@name, Value.node_for(col), Value.node_for(row), Value.node_for(number), tiles,
                                            from: from, now: now, held: (true if @held)))
        @builder.note_held_tile_change(node) if @held
        self
      end

      # Whether a cell given another tile takes that tile's wall (#record_wall_change).
      def walls_follow_tiles? = !@solid_tiles.nil? && !solid_lookup.nil? # :nodoc:

      # Writes one cell as the original's own cell number, on a background drawn from the data
      # pack.
      #
      # ```ruby
      # face = background :face, tiles: pack[:video], map: pack[:face_map], colors: pack[:palette],
      #                          across: 40, set_cells: 0xE500..0xE553
      # face.set_cell 12, 20, 0xE500 + letters[at]    # a letter of the font, as the original writes it
      # ```
      #
      # An original puts words on a screen by storing a cell number in the map: which tile, turned
      # how, from which bank of colours, in its console's layout. `word` is that number, written in
      # the game or worked out as it plays, and it must be one of the cells the background was told
      # with `set_cells:`, since those are the ones the build made pictures for. `col` and `row`
      # count the original's cells, as `across:` does.
      #
      # It is a changed cell as #set_tile makes one: it lasts until the map is put up again, and a
      # place outside the map is left alone. A number written in the game that the background was
      # not told is refused. One worked out as the game plays that it was not told leaves the cell
      # alone.
      #
      # * `now:` - true shows the cell on the frame being drawn, as the original writes it straight
      #   into video memory, rather than in the gap between frames. Where #set_tile's `now:`
      #   changes nothing, this does not either, and where a console refuses it, it refuses this.
      #--
      # The worked-out number is looked up by PackCells#write.
      #++
      def set_cell(col, row, word, now: false)
        return set_cell_by_area(col, row, word, now) if @area_pack_cells

        if @pack_cells.nil?
          raise ArgumentError,
                "background :#{@name} was not told any cells that set_cell can write. To fix this, draw it from the " \
                "data pack and name the cells in `set_cells:`, or use set_tile with a key of its tileset."
        end
        raise ArgumentError, "set_cell was given `now: #{now.inspect}`. It must be true or false." unless [true, false].include?(now)

        @pack_cells.write(self, col, row, word, now: now || nil)
        self
      end

      # #set_cell on a background from the data pack walking between areas: the cell written as the
      # area the game has asked to show tells it, one test of the map showing for each area told the
      # cell. A number written in the game that no area was told is refused, as on one area.
      def set_cell_by_area(col, row, word, now) # :nodoc:
        raise ArgumentError, "set_cell was given `now: #{now.inspect}`. It must be true or false." unless [true, false].include?(now)

        told = @area_pack_cells.each_with_index.select do |cells, _|
          cells && (!word.is_a?(Integer) || cells.writes?(word))
        end
        told = [@area_pack_cells.each_with_index.find { |cells, _| cells }] if told.empty? # its refusal names the cell
        # One area is the only map there is, always showing, so its cell needs no test.
        if map_count == 1
          told.first.first.write(self, col, row, word, now: now || nil)
          return self
        end

        told.each do |cells, area|
          test = PlainRuby::Steps::GameTest.new(showing == area)
          test.open_yes_side
          cells.write(self, col, row, word, now: now || nil)
          test.close_side(nil)
        end
        self
      end

      # The walls follow the cell. A mover is stopped by the walls the tileset's `solid:` tiles
      # make, and those were worked out from the map as declared; a door opened with set_tile
      # has to let it through, and a wall put down has to stop it. So a background whose cells
      # the game changes keeps its walls where the game can change them too (see
      # Builder::Collision#keep_walls_changeable), and the cell's wall goes with its tile: a wall if
      # the tile is `solid:`, floor if not. Walls written apart with `walls:` name no
      # tiles, and stay as written.
      def record_wall_change(col, row, index) # :nodoc:
        return if @solid_tiles.nil? || solid_lookup.nil?

        @builder.record_wall_change(@builder.keep_walls_changeable(solid_lookup, @declaration_tail), col, row,
                                    wall: @solid_tiles.include?(index))
      end

      # Puts a whole different map up on the background, while the game runs.
      #
      # ```ruby
      # rooms = background :rooms, tiles: :dungeon, map: { hall: hall, cave: CAVE }
      # rooms.show_map :cave       # the whole room is the cave now
      # rooms.show_map where       # or whichever map a number the game holds names
      # ```
      #
      # This is walking through a door in a game with many rooms: a room is a map, and going
      # into one is naming it. Written with #set_tile instead, the same change is hundreds of
      # cells, and a picture showing half of each room while they go in.
      #
      # `which` is one of the names the background was declared with, or a number counting from
      # 0 in that order. The number may be one the game works out, so a game with hundreds of
      # rooms can use the room number as the map number.
      #
      # It sets which map is showing, and the copy happens in the gap between frames, so the
      # picture never shows half of each. Naming the map already showing costs nothing.
      #
      # The map comes back exactly as declared. A cell you changed with #set_tile, such as a
      # door you opened, is shut again when you come back to that map. A game that remembers
      # such things opens them again on the way in.
      def show_map(which)
        refuse_on_bitmap_screen!("show_map", instead: "Draw the new picture with `blit`")
        refuse_with_one_map!
        self.showing = resolve_map_number(which)
        # Recorded here as well as remembered, the same way a scroll is: a program with no
        # game loop has no gap between frames to hold the copy for, and then the copy simply
        # happens where it was asked for. The builder drops these once it knows there is a
        # frame boundary to move the work to (Builder#finalize_background_maps).
        node = record(Build.show_map(@name, which: Build.var_ref(shown_map_var)))
        @builder.defer_map_swap(@name, shown_map_var, live_map_var, node)
        self
      end

      # Puts a different map up at once, where the line is written, rather than in the gap
      # between frames.
      #
      # A cell changed after it in the same pass then stays over the new map. That suits a
      # status bar: a few rows, cleared and written together. A big background keeps
      # #show_map, since waiting for the gap is what keeps the picture from showing half of
      # each of two rooms.
      #
      # ```ruby
      # panel.show_map_now :blank
      # panel.set_tile 2, 0, "A"
      # ```
      def show_map_now(which)
        refuse_with_one_map!
        self.showing = resolve_map_number(which)
        record(Build.if_(Build.binop(:!=, Build.var_ref(shown_map_var), Build.var_ref(live_map_var)),
                         Build.show_map(@name, which: Build.var_ref(shown_map_var)),
                         Build.set(live_map_var, Build.var_ref(shown_map_var))))
        self
      end

      # Which of this background's maps is showing, as a Value: 0 for the first declared.
      #
      # Compare it against #map_number to ask which room the game is in.
      #
      # ```ruby
      # in_cave = rooms.showing == rooms.map_number(:cave)
      # ```
      def showing
        refuse_with_one_map!
        Value.new(@builder, Build.var_ref(shown_map_var), name: shown_map_var)
      end

      # The number of a map named when the background was declared: what #showing reads back
      # and what #show_map can be given.
      #
      # It is a plain whole number, known as the game is built, so it can be compared and
      # counted with.
      def map_number(named)
        at = @map_names.index(named)
        raise ArgumentError, unknown_map_message(named) if at.nil?

        at
      end

      # How many maps this background was declared with: 1 for a background of one map.
      def map_count = @map_names.length

      # Draws the whole layer from a different list of colours, from now until it is told
      # otherwise.
      #
      # The lists are declared with `colors`, see-through first, and matched to the list the
      # tiles were drawn from by place: every pixel keeps the place it was drawn at, and only the
      # colour that place shows changes. The scenery is not redrawn and no cell of the map moves.
      #
      # ```ruby
      # rays.draw_with :dusk                                    # one list
      # rays.draw_with [:s0, :s1, :s2, :s3], showing: step      # one of several, by a number
      # rays.draw_with :own                                     # back to the colours it was drawn in
      # ```
      #
      # Shafts of light that shimmer, water that turns murky as you go down, a sky that walks
      # from day to dusk: one set of tiles and a number, where the same picture drawn a dozen
      # times would be a dozen times the tiles.
      #
      # A number outside the set draws the layer in its own colours, so a counter that has run
      # off the end looks right. The change lands in the gap between frames, and only on a
      # frame where the answer changed.
      #
      # A layer whose tiles are drawn from several lists (a backdrop with more colours than one
      # list holds) is recoloured by stepping every list together. Name the lists its tiles were
      # drawn from (`image ..., colors: :sea`) and what each walks through; one number picks the
      # same step of all of them:
      #
      # ```ruby
      # backdrop.draw_with({ sea: %i[sea0 sea1 sea2], sky: %i[sky0 sky1 sky2] }, showing: step)
      # backdrop.draw_with({ sea: :sea_dusk, sky: :sky_dusk })   # one of each, no number
      # ```
      #
      # A list the tiles use that the hash leaves out stays as drawn, and a number outside the
      # steps draws every list as drawn.
      #
      # * `showing:` - a number, written or worked out as the game plays, that picks one of
      #   several lists.
      def draw_with(which, showing: nil)
        refuse_on_bitmap_screen!("draw_with",
                                   instead: "Draw the picture in the colors you want with `blit`")
        steps = recolor_steps(which, showing)
        # Told only lists none of its tiles is drawn from (#allow_undrawn_lists): nothing to recolour.
        return self if steps&.all?(&:none?)

        choice = Value.new(@builder, Build.var_ref(colors_var), name: colors_var)
        recolors.write_choice(choice, steps, showing)
        # Recorded here as well as remembered, the same way `show_map` is: a program with no
        # game loop has no gap between frames to hold the write for, and then it simply
        # happens where it was asked for.
        node = record(Build.background_colors(@name, which: Build.var_ref(colors_var)))
        (@colors_writes ||= []) << node
        @builder.defer_recolor_write(@name, colors_var, live_colors_var, node)
        self
      end

      # Drawn with a list of colours the game changes (`recolor`), for good. The layer's other
      # colours become the sets the list can hold, +sets+ in the order the list counts them, so
      # the number that marks what the list holds (+shown+, the list's own variable) marks what
      # this layer is drawn with too, and the two can never disagree. A number naming none of
      # them is the layer's own colours, which are the list's as it was declared: the colours
      # it holds at power-on, and the ones `recolor :list, :own` puts back.
      #
      # A layer drawn from several lists follows the changing one for the tiles drawn from it
      # alone (`draw_with({ text: :text })`), and its other lists stay as drawn at every step:
      # letters in a list that never changes beside words in one the game fades.
      #
      # Called once the whole program is declared (Builder::ColorLists), when it is known which
      # lists change, and only for a layer that was told `draw_with` the list.
      def follow_changing_list!(list, sets, shown) # :nodoc:
        followed = refuse_following_beside_other_colors!(list)
        @colors_node.recolors = sets.map do |name|
          drawn_lists.each_index.map { |at| at == followed ? list_colors_for(name, at) : drawn_lists[at].last }
        end
        @colors_node.follows = list
        # Where a program has no gap between frames, the writes stay where draw_with was written,
        # and set what the list holds there.
        @colors_writes.each { |node| node.which = Build.var_ref(shown) }
        @builder.defer_recolor_write(@name, shown, live_colors_var, nil)
        self
      end

      # Drawn with several lists of colours the game changes, for good: `draw_with({ sign: :sign,
      # words: :words })`, each of +lists+ told `recolor`. A tile then shows what its own list holds
      # now, each list counted by its own number, as a sprite drawn with that list does.
      #
      # Why it is not #follow_changing_list! Twice. A layer that follows one list keeps the sets
      # that list can hold as its own other colours, and reads the list's number for which to show:
      # one number, one row of sets. Two lists have two numbers, and a row for every pair of them
      # is one list's sets times the other's, for every list added. A console's own games keep
      # no such rows: fading a screen, they write each palette's colours as that palette changes.
      # So this layer keeps no other colours and no number at all. It names the list each of its
      # own lists follows (IR::Nodes::Background#follows_each), and the write that tells a list
      # what to hold is what changes the tiles drawn from it, on the frame it changes the sprites.
      #
      # Called once the whole program is declared (Builder::ColorLists), in place of
      # #follow_changing_list!, for a layer told `draw_with` more than one changing list.
      def follow_changing_lists!(lists) # :nodoc:
        followed = lists.to_h { |list| [refuse_tiles_not_drawn_in!(list), list] }
        raise ArgumentError, following_beside_other_colors_message(lists) unless told_only_to_follow?(followed)

        @colors_node.recolors = []
        @colors_node.follows_each = Array.new(drawn_lists.length) { |at| followed[at] }
        # The layer has no colours of its own to write: the lists' writes are its writes.
        @colors_writes.each { |node| node.parent&.children&.delete(node) }
        @builder.forget_recolor_write(@name)
        self
      end

      # Tiles drawn from a list the game changes, on a layer not told to draw with it, would show
      # the colours the list was declared with on every frame, whatever the game sets it to hold: a
      # picture wrong in silence. Called once the whole program is declared (Builder::ColorLists),
      # for each list told `recolor` and each layer not told `draw_with` it.
      def refuse_unfollowed_changing_list!(list) # :nodoc:
        return if @bitmap

        names = @tile_pictures.map { |pose| @builder.list_name_drawn_from(pose) }.uniq
        return unless names.include?(list)

        fix = names.one? ? "draw_with :#{list}" : "draw_with({ #{list}: :#{list} })"
        raise ArgumentError,
              "#{error_subject} has tiles drawn from :#{list}, and :#{list} was told to hold other colors with " \
              "`recolor`. The background was not told to draw with :#{list}. So these tiles always show the " \
              "colors that :#{list} holds at power-on. To fix this, tell the background `#{fix}`."
      end

      # How many cells across this background's map is: what a game needs to walk it, and
      # what #set_tile holds a column against.
      def cols = @cells[0]

      # How many cells down this background's map is, as #cols is across.
      def rows = @cells[1]

      # The background's walls as a list of Box, each one a sprite can be tested against with
      # `overlaps?`.
      #
      # They are the rectangles the `solid:` tiles of its first map make, joined where they
      # touch. The list is empty if nothing is solid.
      #--
      # Introspection now rather than the way a mover is stopped: a mover asks the grid (see
      # #solid_lookup), which is what lets the walls follow the map showing.
      #++
      def solid_boxes
        @solid_boxes ||= @walls.map { |x, y, w, h| @builder.box(x, y, w, h) }
      end

      # Where the walls are, as something a mover can ask rather than something it has to
      # test against piece by piece.
      #
      # A room's walls make some number of rectangles — a bordered room four, a maze of
      # pillars a hundred — and testing a mover's box against each is work that grows with
      # what the room is made of, and is emitted afresh at every place that moves. The same
      # walls as a grid answer "is this cell a wall" in one read, for any room.
      #
      # A background with several maps keeps one grid per map, laid end to end, and the
      # mover reads the one that is really in the cells. That is what makes walking through
      # a door work: a room is a map, so the walls in front of you are the walls of the map
      # showing, and a cell that is a wall in the hall can be open floor in the cave. The
      # map to read is worked out once per check rather than once per cell, so a room with
      # several maps costs the same nine reads a room with one does.
      #
      # It reads the map really in the cells rather than the one the game last asked for.
      # `show_map` copies between frames, so for the one frame in between those differ — and
      # a player can feel being stopped by a wall that is not on screen, where they cannot
      # feel a frame of lag. The walls always agree with the picture.
      #
      # The grid ships as a byte per cell per map of read-only data (a 30x20 room is 600
      # bytes) and is built once however many movers consult it. nil when the tileset marked
      # nothing solid, which is the same thing #solid_boxes returns as an empty list.
      #
      # The table is named for the scene the background was declared in as well, since two
      # scenes can each declare a background by one name, with walls of their own.
      def solid_lookup # :nodoc:
        return nil if @solid_cells.compact.empty?

        @solid_lookup ||= SolidCells.new(table: @builder.table(walls_table_name, flat_walls, width: :byte),
                                         cols: cols, rows: rows,
                                         tile_w: @tile_size[0], tile_h: @tile_size[1],
                                         name: @name, maps: @solid_cells.length,
                                         # length, not one? — a background whose maps mostly have
                                         # no walls still needs the offset, and `one?` counts the
                                         # grids that are there rather than the maps.
                                         map_var: @solid_cells.length == 1 ? nil : live_map_var)
      end

      # A background's walls as a grid: the table itself, how big the grid is, how big a
      # cell is, and — for a background with several maps — how many maps are in the table
      # and which variable holds which one is live. Everything a mover needs to turn a pixel
      # position into "wall or not". +map_var+ is nil for the ordinary one-map background,
      # whose reads need no map offset at all.
      SolidCells = Data.define(:table, :cols, :rows, :tile_w, :tile_h, :name, :maps, :map_var) do # :nodoc:
        def initialize(maps: 1, map_var: nil, **rest) = super

        # Where a map's grid starts in the table.
        def cells_per_map = cols * rows
      end

      # Slides the view by `dx` and `dy` pixels from where it is now: the usual way to scroll
      # as the player moves.
      #
      # Either may be a number written in the game or one it works out.
      #
      # ```ruby
      # world.scroll_by 2, 0 if held(:right)
      # ```
      def scroll_by(dx, dy)
        ensure_not_affine!("scroll_by")
        record(Build.add(@scroll_x, Value.node_for(dx)))
        record(Build.add(@scroll_y, Value.node_for(dy)))
        record_scroll_write
      end

      # Puts the view's top-left corner at the pixel `x`, `y` of the map, to snap the camera to
      # a spot.
      #
      # Either may be a number written in the game or one it works out.
      #
      # ```ruby
      # world.scroll_to hero.x - 120, 0
      # ```
      def scroll_to(x, y)
        ensure_not_affine!("scroll_to")
        record(Build.set(@scroll_x, Value.node_for(x)))
        record(Build.set(@scroll_y, Value.node_for(y)))
        record_scroll_write
      end

      # Shows the background only inside a box on the screen, from the next frame on, as a
      # scroll shows.
      #
      # ```ruby
      # tall = var :tall, 0
      # game_loop do
      #   tall += 2 if tall < 48
      #   dialogue.show_only_inside 16, 112 - (tall / 2), 208, tall   # opens out from its middle
      # end
      # ```
      #
      # `x` and `y` are the box's top-left corner and `width` and `height` its size, in pixels
      # of the screen, not of the map, and each may be worked out as the game runs. Outside the
      # box the background is not drawn at all, so the layers behind it and the backdrop show
      # there; inside, it is drawn as ever, scrolled where it is scrolled. Sprites are not held
      # to the box. A box past an edge of the screen is the part of it on the screen, and a
      # width or height of 0 or less shows the background nowhere.
      #
      # The console's display does this itself as it draws, so it costs a few register writes in
      # the gap between frames, however big the box.
      #
      # It belongs to the scene the background belongs to: a scene taking over shows its
      # backgrounds everywhere again, and a box set for a background that is not up is set aside
      # when that scene comes back.
      def show_only_inside(x, y, width, height)
        refuse_box_on_bitmap_screen!("show_only_inside")
        x_var, y_var, w_var, h_var, held_var = @builder.hold_background_to_box(@name, in_part: true)
        { x_var => x, y_var => y, w_var => width, h_var => height }.each do |var, value|
          record(Build.set(var, Value.node_for(value)))
        end
        record(Build.set(held_var, Build.int(1)))
        record_box_write
      end

      # Shows the background everywhere again, from the next frame on, setting aside the box of
      # #show_only_inside.
      #
      # A background never held to a box is shown everywhere already, and this changes nothing.
      def show_everywhere
        refuse_box_on_bitmap_screen!("show_everywhere")
        *, held_var = @builder.hold_background_to_box(@name)
        record(Build.set(held_var, Build.int(0)))
        record_box_write
      end

      # Switches the background off, from the next frame on, as a scroll shows.
      #
      # ```ruby
      # sword.hide if passes == 90
      # sword.show if passes == 150
      # ```
      #
      # Nothing of it is drawn, and the layers behind it and the backdrop show where it was. Its
      # map, scroll and turn stay as they are, so #show puts it back as it would be now. Sprites
      # are not hidden with it.
      #
      # It is the box of #show_only_inside with nothing in it, and #show is #show_everywhere, so
      # the two words and the box share one setting: a box set after `hide` shows the background
      # in that box. A display that switches each layer on and off (the Advance's display control
      # register, GBATEK "DISPCNT") does it with that switch, so a background only ever hidden
      # and shown takes none of the display's windows, which a light needs.
      #
      # It belongs to the scene the background belongs to, as a box does: a scene taking over
      # shows its backgrounds again.
      def hide
        refuse_switch_on_bitmap_screen!("hide")
        x_var, y_var, w_var, h_var, held_var = @builder.hold_background_to_box(@name, whole: true)
        [x_var, y_var, w_var, h_var].each { |var| record(Build.set(var, Build.int(0))) }
        record(Build.set(held_var, Build.int(1)))
        record_box_write
      end

      # Switches the background on again after #hide, from the next frame on.
      #
      # A background never hidden shows already, and this changes nothing. It sets aside a box
      # from #show_only_inside too.
      def show
        refuse_switch_on_bitmap_screen!("show")
        show_everywhere
      end

      # Slides each row of the picture sideways by its own amount, so the whole background
      # bends instead of moving as one flat rectangle.
      #
      # The block is given the row (0 at the top of the screen, 159 at the bottom) and gives
      # back how far across that row sits:
      #
      # ```ruby
      # ripple = table :ripple, (0...64).map { |i| (Math.sin(i / 64.0 * 2 * Math::PI) * 4).round }
      # phase  = var :phase, 0
      #
      # water.scroll_each_row { |row| ripple[(row + phase) % ripple.length] }
      # game_loop { phase += 1 }           # the wave travels down the water
      # ```
      #
      # That is wavy water, a heat haze over a desert, a reflection in a lake, a screen melting
      # into a transition. The offset is added to the background's own scroll, so a scrolling
      # background can ripple too. The block is read once for every row of every frame, so a
      # `table` lookup is the usual body: whatever you write there is paid for 160 times a
      # frame.
      #
      # All 160 rows are worked out in the gap between frames, before any of the picture is
      # drawn, which is where a sprite's position is settled too. So a boat riding on the
      # water is showing the same frame the water is.
      #
      # Declare it once, where the background is declared. It keeps running from there, so
      # there is nothing to call each frame; animate it by moving a variable the block reads
      # (the `phase` above). Calling it again on the same background replaces the bend.
      #
      # Rows only bend sideways. A row shows the same part of the map vertically as it
      # always did, which is what a reflection or a haze wants.
      def scroll_each_row(&block)
        unless block
          raise ArgumentError,
                "scroll_each_row needs a block that gives back how far across a row sits: " \
                "#{@name}.scroll_each_row { |row| ripple[row] }"
        end

        @builder.record_row_bend(@name, row_var, &block)
        self
      end

      # Turns the whole background to point `degrees` clockwise from upright, about the middle
      # of the screen or the point #turns_around set.
      #
      # It does to a background what a sprite's `face_angle` does to one picture. `degrees` can
      # be a whole number or an angle the game works out. It needs `screen :rotozoom`.
      #
      # ```ruby
      # world = background :world, tiles: :terrain, map: map
      # world.rotate! 15         # tilt the whole picture
      # world.rotate! spin       # or however far `spin` holds
      # ```
      #
      # The angle wraps, so 370 is the same as 10. A background that never turns keeps its
      # upright angle and costs nothing extra. A number written on the line that declares the
      # background is the angle it starts at.
      #--
      # See Builder::Tiled#make_background_affine for why the screen must be `:rotozoom`.
      #++
      def rotate!(degrees)
        angle_var, = affine_vars
        fixed = Value.fixed_number(degrees)
        declaring = !fixed.nil? && on_declaration_line?
        if fixed
          write_affine_var(angle_var, fixed % 360, declaring)
        else
          self.angle = degrees
          wrap_angle
        end
        record_affine_write
        extend_declaration_tail if declaring
        self
      end

      # Draws the background bigger or smaller as a whole, about the middle of the screen or
      # the point #turns_around set.
      #
      # 1.0 is the size it was drawn at, 2.0 twice as big, 0.5 half: a title screen that zooms
      # in, a warp that zooms out. With no size it hands back the size as a Value you can read,
      # compare and ease. It does to a background what a sprite's `scale` does to one picture,
      # and needs `screen :rotozoom`.
      #
      # ```ruby
      # world.scale 2.0
      # world.scale.approach! 1.0, 0.05    # ease back to the drawn size
      # ```
      def scale(size = nil)
        affine_vars # ensure the size variable exists even if only read below
        return affine_scale_value if size.nil?

        if size.is_a?(Numeric) && size <= 0
          raise ArgumentError,
                "a background's size must be more than 0. You gave #{size.inspect}. " \
                "1.0 is the size it was drawn at, 0.5 is half."
        end

        declaring = size.is_a?(Numeric) && on_declaration_line?
        if declaring
          _, scale_var = affine_vars
          write_affine_var(scale_var, Fraction.scale(size.to_f, Fraction::DEFAULT_BITS), true)
        else
          self.affine_scale_value = size
        end
        record_affine_write
        extend_declaration_tail if declaring
        self
      end

      # The background's heading as a Value: degrees clockwise from upright, from 0 to 359.
      #
      # Reading it needs `screen :rotozoom`, as #rotate! does.
      def angle
        angle_var, = affine_vars
        Value.new(@builder, Build.var_ref(angle_var), name: angle_var)
      end

      # The size variable as a fraction-carrying handle, the same way a sprite's does.
      def affine_scale_value # :nodoc:
        _, scale_var = affine_vars
        Value.new(@builder, Build.var_ref(scale_var), name: scale_var,
                            fraction_bits: Fraction::DEFAULT_BITS)
      end

      # Sets the point of the screen the picture turns around: the one place that stays still
      # while the rest of the picture swings or grows about it.
      #
      # ```ruby
      # background(:sword, tiles: :sword, map: grid).turns_around(120, 72).scale(16.0)
      # ```
      #
      # It is the middle of the screen unless you set one. That is right for a picture that is
      # the whole screen, such as a spinning map or a race track, and wrong for a picture that
      # arrives at a particular spot. Something that flies at the player pivots wherever it
      # comes to rest. At sixteen times magnified only a small patch of the picture is on
      # screen, so a pivot a few pixels off puts the whole thing outside the screen for much of
      # its arrival.
      #
      # Set it once, where the background is declared: a picture turns around one point however
      # many times the game turns it. So it takes numbers you write, not numbers the game works
      # out. Nothing about the picture moves when only the pivot changes: at its drawn size,
      # upright, a background lands in exactly the same place whatever it turns around.
      #
      # The point of the map under the pivot is the same point of the map as of the screen,
      # since the map hangs from the screen's corner. `map_point:` names another:
      #
      # ```ruby
      # background(:sword, tiles: :sword, map: grid).turns_around(120, 72, map_point: [128, 128])
      # ```
      #
      # That puts the middle of a map 256 pixels a side at (120, 72), and it stays there at
      # every size and angle. This does move the picture, since it says where the map lies.
      #
      # * `map_point:` - the point of the map, in its pixels from its top left, that sits at the
      #   pivot, as two whole numbers.
      def turns_around(x, y, map_point: nil)
        affine_vars # this background is one that turns — the same claim `rotate!`/`scale` make
        refuse_bad_map_point!(map_point)
        @builder.set_background_pivot(@name, require_integer_pixel!(x, "x"), require_integer_pixel!(y, "y"),
                                      map_point: map_point)
        self
      end

      private

      # A plain scroll moves a `screen :tiled` layer's own pan registers, which a rotozoom
      # (`screen :rotozoom`) layer doesn't have — it pans by moving its whole matrix instead
      # (see #rotate! / #scale). Friendly error rather than a register write that does
      # nothing on real hardware.
      # On `screen :bitmap` a background is stamped into the one picture where it is
      # declared and nothing draws it again, so there is no cell left to change — the
      # pixels are simply part of the picture now. Drawing over them is what a `blit`
      # already does, so that is what the message says.
      def refuse_on_bitmap_screen!(verb, instead:)
        return unless @bitmap

        raise ArgumentError,
              "background :#{@name} was declared under `screen :bitmap`, where a background is " \
              "painted into the picture once — so there is no cell left for #{verb} to change. " \
              "#{instead}, or use `screen :tiled`."
      end

      # A box is a layer's, and a `screen :bitmap` has no layers: its background is painted into
      # the one picture where it is declared, and nothing draws it again.
      def refuse_box_on_bitmap_screen!(verb)
        return unless @bitmap

        raise ArgumentError,
              "background :#{@name} is on a `screen :bitmap`, so #{verb} cannot hold it to a box. On this " \
              "screen, a background is painted into the picture one time. To show only a part of it, draw " \
              "that part with `blit`, or use `screen :tiled`."
      end

      # ...and a `screen :bitmap` has no layer to switch off either.
      def refuse_switch_on_bitmap_screen!(verb)
        return unless @bitmap

        raise ArgumentError,
              "background :#{@name} is on a `screen :bitmap`, so `#{verb}` cannot switch it off or on. On " \
              "this screen, a background is painted into the picture one time. To remove it, paint the " \
              "area again with `fill_rect` or `blit`, or use `screen :tiled`."
      end

      # Every map's walls, one grid after another, a byte a cell. A map with no walls of its
      # own contributes a grid of zeros rather than being left out, so finding a map's walls
      # stays arithmetic on where the first one starts — the same bargain the maps themselves
      # make (see Builder#finalize_background_maps).
      def flat_walls
        @solid_cells.flat_map do |grid|
          (0...rows).flat_map { |r| (0...cols).map { |c| grid&.dig(r, c) ? 1 : 0 } }
        end
      end

      # The name of the table #solid_lookup keeps the walls in.
      def walls_table_name
        scene = @declaration_tail&.scene
        scene ? :"__solid_#{@name}__in_#{IR::Modes.strip_scene_prefix(scene)}" : :"__solid_#{@name}"
      end

      # A block of cells of a map brought into view a strip at a time. One cell of such a map is
      # changed with set_tile, which a console keeps in the map showing as the view moves; a block
      # (fill_cells, restore_cells) is not made for such a map yet. +verb+ is the block's.
      def refuse_block_on_streamed_map!(verb)
        return unless @streams

        raise ArgumentError,
              "background :#{@name} has a map bigger than 64x64 cells, or maps that are not all one size. " \
              "#{verb} cannot change a block of such a map. To fix this, change its cells one at a time " \
              "with set_tile."
      end

      # A background with one map is the ordinary kind and can never be handed another —
      # there is only the one. Say what to write to get the other kind.
      def refuse_with_one_map!
        return unless @map_names.one?

        raise ArgumentError,
              "background :#{@name} was declared with one map, so there is no other map to show. " \
              "Declare it with several — `background :#{@name}, tiles: ..., map: { hall: HALL, " \
              "cave: CAVE }` — and then `#{@name}.show_map :cave` hands it one of them."
      end

      # Which map +which+ means: a name it was declared with, or a number counting from 0 in
      # that order. A number the game works out is passed straight through — nothing at build
      # time can know which map it will land on, and a value outside the range is held to it
      # when the swap happens.
      def resolve_map_number(which)
        return which unless which.is_a?(Symbol) || which.is_a?(String)

        map_number(which)
      end

      # Which map the game SET to show (written by show_map), and which one is really in
      # the background's cells (written by the copy at the frame boundary). Two rather than
      # one because that is what makes the copy happen exactly when the answer changes.
      def shown_map_var = :"__bg_#{@name}_map"
      def live_map_var = IR::Nodes::Background.map_in_cells_var(@name)

      # ...and the same pair for which list of colours the tiles are drawn from: what the
      # game set, and what is really in the display's table.
      def colors_var = :"__bg_#{@name}_colors"
      def live_colors_var = IR::Nodes::Background.live_colors_var(@name)

      # The other lists this background can be drawn with, made on the first `draw_with` and
      # kept, so several calls in several branches count the same lists the same way. The
      # tiles play the part a sprite's poses play: a list is matched to the one they were
      # drawn from, place by place, so it is the tiles that decide whether another list fits.
      # A background's other colours are steps rather than single lists: each step one list for
      # every list its tiles were drawn from, in the order of #drawn_lists, nil where a list stays as
      # drawn. A layer drawn from one list has steps of one, which is today's swap exactly.
      def recolors
        @recolors ||= begin
          node = @colors_node = @builder.make_background_recolorable(@name)
          node.palettes = drawn_lists.map(&:last)
          node.palette_names = drawn_lists.map(&:first)
          Recolors.new(@builder, subject: error_subject, poses: @tile_pictures,
                                 colors_for: ->(steps) { steps.map { |step| colors_of_step(step) } }).attach_object(node)
        end
      end

      def error_subject = "The background :#{@name}"

      # A layer drawn with a list that changes shows what the list holds, so the tiles that follow
      # it must be drawn in the list's own colours, it must have no other list to take turns with,
      # and no colours of its own to go back to. Its other lists, where its tiles are drawn from
      # several, stay as drawn. Returns which of #drawn_lists follows the list.
      def refuse_following_beside_other_colors!(list)
        followed = refuse_tiles_not_drawn_in!(list)
        return followed if told_only_to_follow?({ followed => list })

        raise ArgumentError, following_beside_other_colors_message([list])
      end

      # Whether all the layer was ever told is to draw each of +followed+ (a place in #drawn_lists
      # to the changing list there) with that list. A list that does not change, told to draw with
      # itself beside them (`draw_with({ text: :text, logo: :logo })`, only :text recoloured), is
      # as drawn, so a game can name every list of a screen it fades without knowing which change.
      def told_only_to_follow?(followed)
        return false if @told_own || !recolors.names.one?

        recolors.names.first.each_with_index.all? do |name, at|
          followed.key?(at) ? name == followed[at] : name.nil? || name == drawn_lists[at].first
        end
      end

      # Which of #drawn_lists follows the changing list +list+, refusing a layer none of whose
      # tiles is drawn in the list's own colours.
      def refuse_tiles_not_drawn_in!(list)
        followed = followed_list_index(list)
        return followed if followed

        raise ArgumentError,
              "#{error_subject} draws with :#{list}, and :#{list} was told to hold other colors with `recolor`. " \
              "So the background shows the colors :#{list} holds, from power-on. Its tiles must be drawn in " \
              "the colors of :#{list}, and they are not. To fix this, give its tiles `image ..., colors: :#{list}`."
      end

      # Which of #drawn_lists follows the changing list +list+: the only one, in its colours, or,
      # for a layer drawn from several, the one given +list+ by name. nil for none.
      def followed_list_index(list)
        declared = @builder.declared_colors(list)
        return (0 if drawn_lists.first.last == declared) if drawn_lists.one?

        drawn_lists.index { |name, colors| name == list && colors == declared }
      end

      def following_beside_other_colors_message(lists)
        return following_several_beside_other_colors_message(lists) unless lists.one?

        list = lists.first
        start = "#{error_subject} draws with :#{list}, and :#{list} was told to hold other colors with `recolor`. " \
                "So the tiles drawn from :#{list} are drawn with :#{list} for good."
        if drawn_lists.one?
          return "#{start} They cannot also draw with other lists or with :own. To fix this, tell the background " \
                 "only `draw_with :#{list}`, and say what :#{list} holds with `recolor :#{list}, ...`."
        end

        "#{start} Its tiles from other lists keep the colors they were drawn in. They cannot draw with other lists, " \
          "and the background cannot draw with :own. To fix this, tell the background only " \
          "`draw_with({ #{list}: :#{list} })`, and say what :#{list} holds with `recolor :#{list}, ...`."
      end

      def following_several_beside_other_colors_message(lists)
        named = lists.map { |list| ":#{list}" }.join(", ")
        "#{error_subject} draws with #{named}, and they were told to hold other colors with `recolor`. So the " \
          "tiles drawn from each of them are drawn with that list for good. Its tiles from other lists keep the " \
          "colors they were drawn in. They cannot draw with other lists, and the background cannot draw with :own. " \
          "To fix this, tell the background only `draw_with({ #{lists.map { |list| "#{list}: :#{list}" }.join(', ')} })`, " \
          "and say what each list holds with `recolor`."
      end

      # The lists this layer's tiles were drawn from, each once, in the order first met: the
      # name each was declared under and its colours (Builder#lists_drawn_from).
      def drawn_lists = @drawn_lists ||= @builder.lists_drawn_from(@tile_pictures, subject: error_subject)

      # One step's colours, a list per palette, each checked against the tiles drawn from it.
      def colors_of_step(step)
        step.each_with_index.map do |name, at|
          next drawn_lists[at].last if name.nil?

          @builder.remember_background_draws_with(name, self)
          list_colors_for(name, at)
        end
      end

      # The colours of the list +name+, for the tiles drawn from the layer's list number +at+,
      # checked against them.
      def list_colors_for(name, at)
        own = drawn_lists[at]
        # Its tiles, and any given its colours themselves (Builder#lists_drawn_from).
        drawn_from_it = @tile_pictures.select do |pose|
          tile_list, tile_colors = @builder.list_drawn_from(pose)
          tile_colors == own.last && (tile_list == own.first || tile_list.nil?)
        end
        @builder.colors_to_draw_with([name], poses: drawn_from_it, subject: error_subject).first
      end

      # What a call to draw_with named, as steps (see #recolors), or nil for the own colours.
      def recolor_steps(which, showing)
        return recolor_steps_from_hash(which, showing) if which.is_a?(Hash)

        names = recolors.requested_lists!(which, showing)
        @told_own = true if names.nil?
        return nil if names.nil?
        return names.map { |name| Array.new(drawn_lists.length, name) } if @one_list_for_every_bank

        unless drawn_lists.length == 1
          raise ArgumentError,
                "#{error_subject} was told to draw_with #{which.inspect}, but its tiles are drawn from " \
                "#{drawn_lists.length} lists of colors. Say what each of them is drawn with, by the name it " \
                "was given: draw_with({ #{drawn_list_names.join(': ..., ')}: ... }#{showing.nil? ? '' : ', showing: ...'})."
        end
        names.map { |name| [name] }
      end

      # A hash of the layer's own lists to what each is drawn with: one list each, or the same
      # number of lists each when a number picks between them.
      #
      # A list no tile is drawn from, where the layer takes those (#allow_undrawn_lists), is held to
      # the same shape and then left out of the steps.
      def recolor_steps_from_hash(named, showing)
        undrawn = named.keys.select { |list| undrawn_list_allowed?(list) }
        at = (named.keys - undrawn).to_h { |list| [list, palette_index!(list)] }
        each_list = named.transform_values { |value| showing.nil? ? [value] : value }
        unless each_list.values.all? { |lists| lists.is_a?(Array) && !lists.empty? && lists.all?(Symbol) }
          raise ArgumentError, uneven_steps_message(named, showing)
        end
        count = each_list.values.first.length
        raise ArgumentError, uneven_steps_message(named, showing) unless each_list.values.all? { |lists| lists.length == count }

        refuse_undeclared_lists!(each_list.values_at(*undrawn).flatten)

        (0...count).map do |step|
          Array.new(drawn_lists.length) { |palette| (list = at.key(palette)) && each_list.fetch(list)[step] }
        end
      end

      # Whether +list+ is one this layer takes though none of its tiles is drawn from it.
      def undrawn_list_allowed?(list)
        @lists_allowed_undrawn.include?(list) && drawn_lists.none? { |name, _| name == list }
      end

      # The lists given to a list no tile is drawn from are checked against no tile, so a name
      # spelled wrong among them is caught here.
      def refuse_undeclared_lists!(names)
        names.each do |name|
          next if @builder.declared_colors(name)

          raise ArgumentError,
                "#{error_subject} was told to draw_with :#{name}, which is not a list of colors. " \
                "Declare it first with `colors :#{name}, [:transparent, ...]`."
        end
      end

      # Where the list +list+ names is among the layer's: by its name, or, for tiles given the
      # same colours themselves, by its colours.
      def palette_index!(list)
        colors = @builder.declared_colors(list)
        at = drawn_lists.index { |name, _| name == list } ||
             (colors && drawn_lists.index { |name, own| name.nil? && own == colors })
        return at if at

        if @walks_areas
          raise ArgumentError,
                "background :#{@name} walks between areas, and it was told to draw :#{list} with other colors. " \
                "No tile of its areas is drawn from :#{list}. To fix this, name a list that the tiles of one of " \
                "its areas are drawn from: #{drawn_list_names.map { |n| ":#{n}" }.join(', ')}."
        end
        raise ArgumentError,
              "#{error_subject} was told to draw :#{list} with other colors, but none of its tiles is drawn " \
              "from :#{list}. Name a list its tiles were given with `image ..., colors: :name`" \
              "#{drawn_list_names.empty? ? '' : " — #{drawn_list_names.map { |n| ":#{n}" }.join(', ')}"}."
      end

      def uneven_steps_message(named, showing)
        if showing.nil?
          "#{error_subject} was told to draw_with #{named.inspect}. With no showing:, give each list one list " \
            "of colors by name, like draw_with({ sea: :sea_dusk })."
        else
          "#{error_subject} was told to draw_with #{named.inspect}, showing: .... showing: picks the same step of " \
            "every list, so give each list the same number of lists of colors, like " \
            "draw_with({ sea: [:sea0, :sea1], sky: [:sky0, :sky1] }, showing: step)."
        end
      end

      # The names this layer's lists were declared under, where they were.
      def drawn_list_names = drawn_lists.filter_map { |name, colors| name || @builder.name_of_colors(colors) }

      def unknown_map_message(named)
        "background :#{@name} has no map #{named.inspect}. Its maps are " \
          "#{@map_names.map(&:inspect).join(', ')}."
      end

      def unknown_tile_message(tile, keys: @tile_index.keys)
        known = keys.first(8).map(&:inspect).join(", ")
        "background :#{@name} has no tile #{tile.inspect}, so set_tile cannot put one there. Its " \
          "tiles are #{known}#{keys.size > 8 ? ', and more' : ''} — the ones its tileset names."
      end

      # Asked of the build rather than kept here — see Builder#background_turns? for why
      # a copy on this handle was a second answer to keep in step.
      def turning_layer? = @builder.background_turns?(@name)

      def ensure_not_affine!(verb)
        return unless turning_layer?

        raise ArgumentError,
              "#{@name}.#{verb} scrolls a background straight. Background :#{@name} turns and " \
              "resizes instead. A layer that turns has no scroll of its own. To move it, use " \
              "#{@name}.rotate! or #{@name}.scale."
      end

      # This background's angle and size variables, allocated the first time they are
      # asked for. The build holds them, so asking again is a lookup rather than a second
      # pair; a friendly error if the screen cannot turn or resize a background at all
      # (see Builder::Tiled#make_background_affine).
      def affine_vars
        @builder.make_background_affine(@name)
      end

      # Is this turn still part of declaring the background, or something the frame does
      # to it afterwards?
      #
      # `background(:sword, tiles: :t, map: grid).scale(16.0)` is one line, and the size in
      # it sets how big the picture starts. A `scale` written further down a scene is a
      # different statement meaning a different thing — set the size, now, every time this
      # runs — and the two have to run in different places, because a scene's body is
      # reached on every frame that scene is up.
      #
      # The question is answered by where the build point is rather than by reading the
      # author's line: nothing has been recorded since this background was declared, so
      # this call is still on that line.
      def on_declaration_line?
        !@declaration_tail.nil? && @builder.last_statement.equal?(@declaration_tail)
      end

      # ...and a turn that was part of the declaration leaves the declaration open, so a
      # second one chained after it (`.scale(16.0).rotate!(45)`) is part of it too.
      def extend_declaration_tail
        @declaration_tail = @builder.last_statement
      end

      # The point is settled while the program is written, so it takes a number rather than
      # something the game works out. A pivot that moved would be its own effect and a real
      # one; refusing it here says so plainly instead of half-doing it.
      def require_integer_pixel!(value, axis)
        return value if value.is_a?(Integer)

        raise ArgumentError,
              "#{@name}.turns_around takes numbers you write, not a value the game works out. " \
              "You gave #{axis} = #{value.inspect}. The point a picture turns around is settled " \
              "when you write the program. To fix this, write #{axis} as a whole number of pixels."
      end

      # `map_point:` is two whole numbers written in the program, as the pivot is.
      def refuse_bad_map_point!(map_point)
        return if map_point.nil? || (map_point.is_a?(Array) && map_point.length == 2 && map_point.all?(Integer))

        raise ArgumentError,
              "#{@name}.turns_around was given map_point: #{map_point.inspect}. map_point: is the point of the " \
              "background's map that sits at the pivot. To fix this, give two whole numbers of pixels from the " \
              "map's top left, like `map_point: [128, 128]`."
      end

      # A number written on the declaration line is what the background starts at, so it is
      # set once at power-on; the same number written anywhere else is a write this frame
      # makes, and stays where the author put it.
      def write_affine_var(var, value, declaring)
        return @builder.set_at_boot(var, value) if declaring

        record(Build.set(var, Build.int(value)))
      end

      # A turn past 359 or below 0 wraps around, same as a sprite's #face_angle — see
      # HardwareSprite#wrap_angle, whose exact steps this mirrors.
      def wrap_angle
        self.angle = angle - (angle / 360 * 360)
        self.angle += 360 if angle < 0
      end

      # Write this frame's angle/scale to the display — recorded at the call site, like
      # #record_scroll_write for a scroll, and moved to the frame boundary at finalize (see
      # Builder#finalize_background_affine) so the console never shows a half-turned frame.
      def record_affine_write
        angle_var, scale_var = affine_vars
        node = record(Build.affine_background(@name, angle: Build.var_ref(angle_var), scale: Build.var_ref(scale_var),
                                                     around: @builder.console.middle))
        @builder.record_inline_affine_node(node)
      end

      # The variable the row number is put in before the block's offset is worked out —
      # one per background, so two bending backgrounds cannot tread on each other.
      def row_var
        :"__bg_#{@name}_row"
      end

      # Show the background at its current offset.
      #
      # Moving the view means writing the display's scroll position, and the display
      # reads that position again for every line it draws — so writing it while the
      # picture is being drawn moves only the lines below that point, and the screen
      # tears in half. The safe moment is the gap between frames.
      #
      # Rather than ask a game to know that, the write is made once a frame, in the
      # gap, together with the sprites (see Builder#emit_frame_boundary). Scrolling
      # can then be computed anywhere in a frame, however long the frame's work runs,
      # and it can never tear. The node is still recorded here as well; the builder
      # drops these once it knows the program has a frame boundary to move them to.
      def record_scroll_write
        node = record(Build.scroll_background(@name, x: Build.var_ref(@scroll_x), y: Build.var_ref(@scroll_y)))
        @builder.defer_scroll_write(@name, @scroll_x, @scroll_y, node)
        self
      end

      # Show the box where it is now. Recorded here as well as moved to the gap between frames,
      # as a scroll is (#record_scroll_write): a program with no game loop has no gap to move it to.
      def record_box_write
        box = IR::Nodes::Background.box_vars(@name).map { |var| Build.var_ref(var) }
        node = record(Build.box_background(@name, x: box[0], y: box[1], width: box[2], height: box[3], held: box[4]))
        @builder.record_inline_box_node(node)
        self
      end

      def record(node)
        @builder.record_statement(node)
      end
    end
  end
end
