# frozen_string_literal: true

module VBlank
  class Builder
    # Tiled backgrounds
    #
    # Most console games draw a level not pixel by pixel but out of a small set of reusable little
    # pictures, called tiles, stamped onto a grid by a map. You define a tile set, which says which
    # character means which tile picture, and a background, which is a map of those characters.
    # The framework paints the grid for you. A tile is just an `image`, so tiles are made like any
    # other art: text, a list of numbers or an imported picture.
    #
    # ```ruby picture=still
    # VBlank.game "DUNGEON", consoles: %i[gba] do
    #   screen :tiled, backdrop: rgb(3, 4, 7)
    #   image(:brick, "#" => :orange,
    #                 "-" => rgb(12, 6, 3)) do
    #     ("###-####\n" * 3 + "--------\n") * 2
    #   end
    #   image(:floor, "." => rgb(9, 8, 7)) do
    #     "........\n" * 8
    #   end
    #   tiles :dungeon, "#" => :brick,
    #                   "." => :floor
    #   background :level, tiles: :dungeon,
    #                      map: <<~MAP
    #     ############
    #     #..........#
    #     #..##..##..#
    #     #..........#
    #     ############
    #   MAP
    #   game_loop {}
    # end
    # ```
    #
    # ```ruby
    # image :brick, "#" => :gray  do <<~ART … ART end   # each tile is an image
    # image :floor, "." => :black do <<~ART … ART end
    # tiles :dungeon, "#" => :brick, "." => :floor       # the character -> tile map
    # background :level, tiles: :dungeon, map: <<~MAP     # where each tile goes
    #   ##########
    #   #........#
    #   ##########
    # MAP
    # ```
    #
    # There are three ways to get a level. Type it as rows of characters. Draw it in a map editor
    # such as Tiled and give the editor's CSV export with `from:`, after importing the whole tile
    # sheet as numbered tiles. Or, for a level the build works out, decoded from somewhere or
    # generated, write rows of arrays straight into `map:`. All three produce a grid of references
    # into a tile set.
    #
    # One `background` paints a single layer. Declare several and they stack: the first is the
    # backmost and each later one is in front. Each can be scrolled on its own, so that a near and a
    # far layer scroll at different speeds for parallax. `status_bar` is a strip of tiles fixed to
    # the screen.
    #--
    # See Background. All the console's tile machinery, where the tile pictures live in video
    # memory, the map layout and the background-control registers, is managed and never appears in
    # these verbs.
    #++
    module Tiled
      # What the build knows about one background, from the line that declares it to the
      # last pass before the tree is handed over.
      #
      # A background gathers its facts over a whole program. It is declared in one place,
      # and then — on the handle, in another file, inside a scene — it is scrolled, turned,
      # handed a different map, or has its rows bent. Each of those needs a write put in
      # the gap between frames at the end of the build, and several of them are refused
      # against each other: a layer that turns has no scroll of its own, so scrolling one
      # and then turning it is a friendly error either way round.
      #
      # One record per background, rather than one collection per fact, because the facts
      # are read together. "Can this background turn?" is three of them at once, and every
      # rule that spans two would otherwise be a lookup in each, kept in step by hand —
      # the exact failure `pool` exists to spare a game writing its own data.
      #
      # +boxed_in_part+ is true once the game holds it to a box of some size (`show_only_inside`),
      # +hidden_whole+ is true once the game hides it (`hide`).
      #
      # Every field but +node+, +scene_gates+, +bends_rows+, +pivot+, +pivot_map_point+, +boxed_in_part+
      # and +hidden_whole+ holds
      # the name of a hidden variable the build allocated, and is nil until the program does the
      # thing that needs it. So a background that is never scrolled has no +scroll_x+, and asking
      # #scrolls? is the same question as asking whether the game ever scrolled it.
      DeclaredBackground = Struct.new(:node, :scroll_x, :scroll_y, :shown_map, :live_map,  # :nodoc:
                                      :angle, :scale, :scene_gates, :bends_rows, :pivot, :pivot_map_point,
                                      :shown_colors, :live_colors, :box, :held, :boxed_in_part, :hidden_whole,
                                      keyword_init: true) do
        def scrolls? = !scroll_x.nil?
        def held_to_box? = !box.nil?
        def swaps_maps? = !shown_map.nil?
        def bends_rows? = !bends_rows.nil?
        def draws_with_colors? = !shown_colors.nil?

        # Has the build wired this one up to turn — allocated its angle and size, and
        # arranged for its matrix to be written every frame? Not the same question as
        # whether it is a layer of the turning kind, which a `screen :rotozoom`
        # background is from the line that declares it and before anything turns it.
        # That one is Builder#background_turns?, off the node's own flag.
        def turns_each_frame? = !angle.nil?
      end

      # Defines a tile set: the tile pictures a background is drawn from.
      #
      # There are two ways to make one. By character, give a map from a key to the tile `image` it
      # stands for. The images must already be defined and must all be the same size. The keys are
      # the alphabet a `background` map is drawn with.
      #
      # ```ruby
      # tiles :dungeon, "#" => :brick, "." => :floor
      # ```
      #
      # A key need not be a character. A game that decodes its level from somewhere has a tile
      # number for each cell and never had a character, and a real screenful holds more different
      # tiles than anybody would invent an alphabet for. So a key is whatever the game already calls
      # its tiles, and the `background` map is written in those.
      #
      # ```ruby
      # tiles :room, 0 => :tile_0, 1 => :tile_1, 2 => :tile_2
      # ```
      #
      # You can import the tiles from a tile sheet, one image file holding the tiles in a grid, with
      # `from:` and `tile:`. Each key then points at a cell of the sheet instead of a hand-drawn
      # image: a cell number, counting left to right and top to bottom, or `[column, row]`.
      #
      # ```ruby
      # tiles :dungeon, from: "dungeon.png", tile: 8, "#" => 0, "." => 1
      # ```
      #
      # By number, import the whole tile sheet with `from:` and `tile:` and no keys. Every cell
      # becomes a numbered tile: 1, 2, 3, left to right and then top to bottom, which is the
      # numbering a map editor such as Tiled writes into a CSV export. A background over this tile
      # set is written as those numbers, the editor's CSV (see `background from:`) or a grid of
      # numbers written into `map:`.
      #
      # ```ruby
      # tiles :world, from: "world.png", tile: 8
      # ```
      #
      # Add `solid:` to mark which tiles are walls that a sprite cannot move through. It takes the
      # keys that block, whichever kind this tile set has: characters (`solid: ["#"]`, or one
      # character `solid: "#"`) or tile numbers (`solid: [1, 2]`). A background built from this
      # tile set then knows where its walls are, so a sprite told to be `blocked_by` it stops at
      # them.
      #
      # * `name` - the tile set's name, which `background(tiles:)` refers to.
      # * `tile_map` - one entry for each tile, from its key to an image name or, with `from:`, to
      #   a cell. Leave it empty with `from:` to import the whole sheet as numbered tiles. These
      #   options go in the same hash:
      # * `from:` - an image file holding the tiles in a grid, found next to your script. With a
      #   list the game owns, a set of tiles whose pixels the game paints while it runs.
      # * `tile:` - each tile's size in the sheet, in pixels.
      # * `transparent:` - `true` to honour a cut-out background.
      # * `solid:` - the keys of the tiles that are walls.
      # * `black:` - `:see_through` (the default) lets the layer behind show through black, and
      #   `:solid` keeps black as a colour, so that an outline in black does not come out full of
      #   holes.
      #--
      # Black as a COLOUR. A tile has no marker of its own for "nothing here", so black drawn by
      # colour stands for it. A tile set that sets `black: :solid` holds its pictures as place
      # numbers, every backend then reads them as it reads any such art, and black takes a colour
      # slot of its own on the console. See #solid_black_image. The pixels of a list the game owns
      # are kept in a list of its own (see TileRuns).
      #++
      def tiles(name, tile_map)
        # Pixels the game paints itself, kept in a list of its own (see TileRuns).
        return define_tile_run(name, tile_map) if tile_map[:from].is_a?(DSL::List)

        tile_map = tile_map.dup
        solid = Array(tile_map.delete(:solid)) # tiles that block movement, named by their keys
        from = tile_map.delete(:from)          # a tile sheet to import the tiles from, if any
        tile = tile_map.delete(:tile)          # each tile's size in that sheet
        transparent = tile_map.delete(:transparent) { false }
        black = tile_map.delete(:black) { :see_through }
        refuse_unknown_black!(name, black)

        # A sheet with no keys at all: import every cell as a numbered tile, ready for a
        # map that picks tiles by that number.
        return define_sheet_tileset(name, from, tile, transparent, solid, black) if from && tile_map.empty?

        raise ArgumentError, "tiles :#{name} needs at least one key => tile mapping" if tile_map.empty?

        # With `from:`, each key named a cell; import those cells into images so the rest
        # of this method sees the same key => image-name map as inline.
        tile_map = import_tile_cells(name, from, tile, transparent, tile_map) if from

        unknown = solid.reject { |key| tile_map.key?(key) }
        unless unknown.empty?
          raise ArgumentError,
                "tiles :#{name}: solid #{unknown.map(&:inspect).join(', ')} " \
                "#{unknown.one? ? 'is' : 'are'} not in the tileset. Mark as solid only its tiles. " \
                "#{tileset_tiles_in_words(tile_map.keys)}"
        end

        sizes = tile_map.map do |key, img|
          @images[img] || raise(ArgumentError,
                                 "tiles :#{name}: tile #{key.inspect} => :#{img} is not a defined image. " \
                                 "Define it first with `image :#{img}, ...`.")
        end
        unless sizes.uniq.size == 1
          raise ArgumentError,
                "tiles :#{name}: all tiles must be the same size. They form a uniform grid. " \
                "These sizes are different: #{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}."
        end

        tile_map = tile_map.transform_values { |image| solid_black_image(image) } if black == :solid

        # Number the tiles 1, 2, 3… in the order they're listed, so this same tileset
        # can also be drawn from a CSV map of numbers (not only from its own keys).
        by_number = tile_map.values.each_with_index.to_h { |img, i| [i + 1, img] }
        @tilesets[name] = { by_key: tile_map.dup, by_number: by_number,
                            tile_w: sizes.first[0], tile_h: sizes.first[1],
                            solid_images: solid.map { |key| tile_map[key] }.uniq }
      end

      private def refuse_unknown_black!(name, black)
        return if BLACK_ANSWERS.include?(black)

        raise ArgumentError,
              "tiles :#{name}: black: #{black.inspect} is not an answer. Use black: :see_through, which lets the " \
              "layer behind show through black, or black: :solid, which keeps black as a colour."
      end

      # Black as a COLOUR. A tile has no marker of its own for "nothing here", so black drawn by colour
      # stands for it, and an outline in black comes out full of holes. Art given as place numbers
      # never had that trouble: place 0 is see-through and black at any other place is a colour. So
      # a tileset that sets `black: :solid` holds its pictures as place numbers, every backend then
      # reads them as it reads any such art, and black takes a colour slot of its own on the console.
      #
      # This is a copy of the picture, once however many tilesets ask, and the picture itself keeps
      # its answer for any tileset that did not ask: the same tile stored twice, which is what two
      # answers about one tile cost.
      #
      # A picture given as colours in a list read from the data pack as the game starts. Such a list
      # holds a marker for each colour (IR::StartFile), and the picture's pixels are the game's own
      # colours, so no pixel is at any place of it: the build cannot find the place the all-in-one
      # build finds. Places added after the list's own would grow it past sixteen, or past what the
      # list has. So the copy counts into a list of the colours its pixels draw, with no name, which
      # shows the same picture. Swapping it for another list goes by place, and is refused as for the
      # picture itself (Images#refuse_swapping_unplaced_pixels!, which asks #solid_black_source).
      private def solid_black_image(source)
        picture = @pictures[source]
        return source if picture.nil? || picture.places

        @solid_black_images[source] ||= begin
          unplaced = picture.colors&.any? { |color| IR::StartFile.marker?(color) }
          table = unplaced ? [nil] : (picture.colors&.dup || [nil])
          places = Array.new(picture.width * picture.height) do |at|
            next 0 unless picture.drawn_at?(at)

            color = picture.color_at(at)
            table << color unless (1...table.length).any? { |place| table[place] == color }
            (1...table.length).find { |place| table[place] == color }
          end
          name = free_name_after(source, :solid_black)
          define_placed_image(name, places: places, width: picture.width, height: picture.height,
                                    colors: table.map { |color| color || :transparent },
                                    colors_name: (picture.colors_name unless unplaced))
          name
        end
      end

      # The picture +pose+ is the solid-black copy of (#solid_black_image), or nil for any other.
      private def solid_black_source(pose) = @solid_black_images.key(pose)

      # Paints a tiled background: a tile set plus a map of which tile goes in each cell of the
      # grid. It returns a handle that you can scroll with `world.scroll_by dx, dy`.
      #
      # The map can be written in two ways. `map:` is the grid of tile set keys. A row is a string
      # of them, one character for each cell, with rows separated by newlines, which is how a level
      # somebody typed is written. A space leaves the cell empty, so the background shows through.
      # A row can instead be an array with one element for each cell, and a cell is then whatever
      # the tile set is keyed by. `nil` is the empty cell. That is how a level the build works out
      # is written.
      #
      # ```ruby
      # background :level, tiles: :dungeon, map: <<~MAP
      #   ##########
      #   #........#
      #   ##########
      # MAP
      #
      # background :room, tiles: :room, map: [[0, 1, 1, 2],
      #                                       [3, nil, 1, 2]]
      # ```
      #
      # `from:` is a CSV tile map exported from a map editor such as Tiled: a grid of tile numbers,
      # as `tiles from:` numbers an imported sheet, with one row on each line. A `0` leaves the cell
      # empty. The file is found next to your script. Use it for editor files. For a grid the build
      # worked out, write it into `map:`.
      #
      # ```ruby
      # background :level, tiles: :world, from: "level.csv"
      # ```
      #
      # To have several maps, one showing at a time, give `map:` (or `from:`) a hash of them, from a
      # name to a map. The background can then be handed a whole different map while the game runs,
      # such as a room for each map, a floor for each map, or a level that reshapes. The first is the
      # one showing when the game starts.
      #
      # ```ruby
      # rooms = background :rooms, tiles: :dungeon, map: { hall: hall, cave: CAVE }
      # rooms.show_map :cave       # the whole room is the cave now
      # ```
      #
      # A map bigger than the console's grid, or maps of different sizes, are kept whole in the
      # cartridge and brought into view a strip at a time as the view moves. Past the edge of such a
      # map the view shows nothing, rather than the map coming round again.
      #
      # What stops a mover is given apart from what it sees. `walls:` is a grid of its own, the
      # same shape as the map, that marks which cells a mover cannot enter. Without it the walls
      # are the tile set's `solid:` tiles, which is what a small game wants. With it the two are
      # separate data, as a real game's are: a room's collision is made, imported or decoded
      # beside its picture and not read off which tile was drawn. A map that `walls:` does not name
      # has no walls, so a room that is scenery and not a place, such as a fly-over map or a
      # cut-scene picture, needs one line less and not a different background. A cell is a wall
      # unless it is blank, and blank is a space, a `.`, a `0` or nothing at all.
      #
      # ```ruby
      # rooms = background :rooms, tiles: :dungeon,
      #                    map:   { hall: hall,       cave: cave, sky: SKY },
      #                    walls: { hall: HALL_WALLS, cave: CAVE_WALLS }
      # ```
      #
      # `above_row: 32` shows the background only on the rows above row 32, and `alone: true` shows
      # it alone there, as a console's own status bar often is. No other background is drawn above
      # the row, so its see-through pixels show the backdrop and not the field under it. Sprites are
      # still drawn there, as the stack puts them. `alone: :without_sprites` keeps the sprites out
      # above the row too, so only the bar and the backdrop show there.
      #
      # ```ruby
      # background :bar, tiles: :hud, map: BAR_ROWS, above_row: 32, alone: :without_sprites
      # ```
      #
      # `held: true` keeps every `set_tile` of a pass and shows them all on the next frame, for
      # cells that change together, such as a message box that grows a size a frame. Without it a
      # cell is written where the game asks for it, which is the cheapest thing and right for a door
      # or a pot, and a box of seventy cells can show part of each size.
      #
      # ```ruby
      # box = background :box, tiles: :frame, map: EMPTY_BOX, held: true
      # ```
      #
      # * `name` - the background's name, as a symbol.
      # * `tiles:` - a tile set made with `tiles`, or a hash from an area to a tile set for a
      #   background that walks between areas.
      # * `map:` - the grid of tile set keys, as rows of characters or rows of keys, or a hash from
      #   a name to a grid for a background with several maps.
      # * `from:` - the path of a CSV tile map, or a hash from a name to a path.
      # * `walls:` - which cells stop a mover, apart from the picture. One grid, or a hash keyed
      #   like `map:`.
      # * `above_row:` - show the background only on the rows above this row.
      # * `alone:` - with `above_row:`, `true` shows no other background above the row, and
      #   `:without_sprites` shows no sprite either.
      # * `held:` - `true` keeps each pass's `set_tile` changes and shows them together on the next
      #   frame.
      # * `colors:` - the colours the tiles are drawn from.
      # * `across:` and `cell:` - for a background read from the data pack, the width of its map
      #   and the size of a cell.
      # * `set_cells:` - for a background from the data pack, the original's cell numbers that
      #   `set_cell` may write later.
      # * `cells_in_front:` - the cells that are drawn in front of sprites that are `in_front:`.
      #--
      # Why `held:` is a setting, and why it is off unless asked for. The display reads the map while
      # it draws, so a change shows on this frame or the next by where on the screen the display has
      # got to, and nobody can tell for one cell. A message box growing a size a frame is seventy
      # cells, and there the same writes show part of each size, or a size early on a quiet frame
      # and on time on a busy one. The console's own games keep a copy of such a layer's map in work
      # memory, change the copy during the frame, and copy it in between frames. This keeps the
      # changes themselves in work memory instead, a word each, and writes them in the gap between
      # frames: the same picture, without copying the cells nobody changed, and without a second
      # copy of the map to keep in step when show_map or a scene puts the map up again. A game that
      # does not set it builds what it built before.
      #
      # See #background_from_sets for the several-areas form, IR::TileMap.streams? for the bigger
      # maps, Builder::PackBackgrounds for the data pack forms, and Background for the handle.
      #++
      def background(name, tiles:, map: nil, from: nil, walls: nil, above_row: nil, alone: false, held: false, colors: nil,
                     across: nil, cell: nil, set_cells: nil, cells_in_front: nil)
        if pack_areas?(tiles, map, colors)
          # Each area's own slots from the data pack (Builder::PackBackgrounds), walked between.
          return declare_pack_background_areas(name, tiles: tiles, map: map, colors: colors, across: across, cell: cell || 8,
                                                     set_cells: set_cells, cells_in_front: cells_in_front, walls: walls,
                                                     above_row: above_row, alone: alone, held: held)
        end
        if tiles.is_a?(DSL::PackSlot)
          # The original's own tiles, map and colours, from the data pack (Builder::PackBackgrounds).
          return declare_pack_background(name, tiles: tiles, map: map, colors: colors, across: across, cell: cell || 8,
                                               set_cells: set_cells, cells_in_front: cells_in_front, walls: walls,
                                               above_row: above_row, alone: alone, held: held)
        end

        refuse_pack_background_settings!(name, colors, across, cell, set_cells, cells_in_front)
        refuse_bad_above_row!(name, above_row)
        refuse_bad_alone!(name, alone, above_row)
        refuse_bad_held!(name, held)
        declare_background(name, tiles: tiles, map: map, from: from, walls: walls, above_row: above_row, alone: alone,
                                 held: held)
      end

      # Makes a status bar: a strip of tiles fixed to the screen from a row down to the bottom, over
      # a field that scrolls and changes under it.
      #
      # It is the score along the bottom of a pinball table, or the lives and keys along the bottom
      # of a dungeon. It does not scroll. It hides the backgrounds under it from its top to the
      # bottom of the screen, so its see-through pixels, and the rows past the end of its map, show
      # the backdrop and never the field. Sprites, and text on a tiled screen, are drawn over it.
      # Its map is written the way a `background`'s is, and `set_tile` changes one of its cells. One
      # status bar shows at a time, and it needs a `screen :tiled`.
      #
      # ```ruby
      # bar = status_bar :score, tiles: :hud, map: SCORE_BAR, top: screen_height - 16
      # game_loop do
      #   bar.move_to screen_height if ball_y > 132        # out of view while the ball is low
      #   bar.move_to screen_height - 16 if ball_y <= 132
      # end
      # ```
      #
      # * `name` - the bar's name, as a symbol.
      # * `tiles:` - a tile set made with `tiles`.
      # * `map:` - the bar's grid, as a background's. A hash from names to grids gives it several,
      #   and `show_map` changes the whole bar at once.
      # * `top:` - the screen row its top is at to begin with.
      #
      # Returns a handle that answers `move_to`, `top`, `set_tile` and `show_map`.
      #--
      # On the Game Boy Color it is the console's window, a second layer that every Color has beside
      # its one background, so it takes nothing from the field. On the Advance it is one of the four
      # background layers.
      #++
      def status_bar(name, tiles:, map:, top:)
        refuse_unplaceable_status_bar!(name, tiles, map, top)
        background = declare_background(name, tiles: tiles, map: map, bar_top: top)
        top_var = IR::Nodes::Background.bar_top_var(name)
        at_boot(Build.set(top_var, Build.int(top)))
        ensure_var(top_var)
        DSL::StatusBar.new(self, name: name, top_var: top_var, background: background)
      end

      private

      # colors:, across:, cell:, set_cells: and cells_in_front: describe a background whose tiles come
      # from the data pack.
      def refuse_pack_background_settings!(name, colors, across, cell, set_cells, cells_in_front)
        given = { colors: colors, across: across, cell: cell, set_cells: set_cells, cells_in_front: cells_in_front }.compact.keys
        return if given.empty?

        raise ArgumentError, "background :#{name} was given #{given.map { |key| "#{key}:" }.join(', ')}, which only a " \
                             "background drawn from the data pack takes. To fix this, give it `tiles: pack[:video]`, " \
                             "or leave #{given.map { |key| "#{key}:" }.join(', ')} out."
      end

      # A status bar the console can keep where it is put: on a tiled screen, one tileset, every
      # map no bigger than the console's grid of 32 by 32 cells, its top a number written in the
      # program.
      def refuse_unplaceable_status_bar!(name, tiles, map, top)
        unless @screen_mode == :tiled
          raise ArgumentError,
                "status_bar :#{name} needs a `screen :tiled`. A status bar is a layer of tiles, and " \
                "this screen has no layers. To fix this, declare the bar in a scene with `screen :tiled`."
        end
        if current_layer
          raise ArgumentError,
                "status_bar :#{name} is declared in `layer :#{current_layer}`. A status bar is always in " \
                "front of the backgrounds and behind the sprites, so it takes no layer. To fix this, " \
                "declare it outside the `layer` block."
        end
        unless tiles.is_a?(Symbol)
          raise ArgumentError,
                "status_bar :#{name} is drawn from one tileset. To fix this, give `tiles:` the name of " \
                "a tileset."
        end
        unless top.is_a?(Integer)
          raise ArgumentError,
                "status_bar :#{name}: `top:` is #{top.inspect}. It must be a whole number, the screen row " \
                "the bar starts at. To move the bar as the game runs, use `move_to`."
        end
        grids = map.is_a?(Hash) ? map.values : [map]
        return if grids.all? do |grid|
          rows = background_rows(name, grid)
          rows.length <= IR::TileMap::BAR_CELLS && rows.all? { |row| row.length <= IR::TileMap::BAR_CELLS }
        end

        raise ArgumentError,
              "status_bar :#{name} has a map of more than #{IR::TileMap::BAR_CELLS} cells across or down. A " \
              "status bar holds #{IR::TileMap::BAR_CELLS} by #{IR::TileMap::BAR_CELLS} cells. To fix this, " \
              "make its map smaller."
      end

      # One name in several scenes is a background of each, and two things do not fit that. A
      # declaration outside every scene is on screen in all of them, so beside a scene's own it
      # would be two backgrounds up together under one name. And a bend or a turn is kept once for
      # each name by every lowering, so a second scene's would be lost or would land on the first.
      def refuse_name_in_two_places!(name, declared)
        if declared.scene_gates.include?(nil) != @current_scene_gate.nil?
          raise ArgumentError,
                "background :#{name} is declared in a scene and also outside every scene. A background " \
                "outside every scene shows in all of them, so two backgrounds show at one time with one " \
                "name. To fix this, give one of them a different name."
        end
        return if declared.scene_gates.include?(@current_scene_gate)

        refuse_changed_name_in_two_scenes!(name, "bends its rows with `scroll_each_row`") if declared.bends_rows
        refuse_changed_name_in_two_scenes!(name, "turns or resizes") if declared.turns_each_frame?
      end

      def refuse_changed_name_in_two_scenes!(name, change)
        raise ArgumentError,
              "background :#{name} is declared in two scenes and #{change}. A name keeps one of these for " \
              "the whole game, so one scene would show it wrong. To fix this, give each scene's background " \
              "a different name."
      end

      def refuse_bad_above_row!(name, above_row)
        return if above_row.nil? || (above_row.is_a?(Integer) && above_row.between?(1, screen_height - 1))

        raise ArgumentError, "background :#{name} has `above_row: #{above_row.inspect}`, and that is not a row of the " \
                             "screen. Give a number written in the program, from 1 to #{screen_height - 1}."
      end

      # What `alone:` takes: alone with the sprites, not alone, or alone without the sprites too.
      ALONE_SETTINGS = [true, false, :without_sprites].freeze  # :nodoc:

      # `alone:` is one of ALONE_SETTINGS, and set only beside `above_row:`, whose rows it is about.
      def refuse_bad_alone!(name, alone, above_row)
        unless ALONE_SETTINGS.include?(alone)
          raise ArgumentError, "background :#{name} has `alone: #{alone.inspect}`. `alone:` must be true, false or " \
                               ":without_sprites."
        end
        return unless alone && above_row.nil?

        raise ArgumentError, "background :#{name} has `alone: #{alone.inspect}` but no `above_row:`. `alone:` shows a " \
                             "background alone above its row. To fix this, give it `above_row:` too, or remove `alone:`."
      end

      # `held:` is true or false, on a screen with cells to change.
      def refuse_bad_held!(name, held)
        unless [true, false].include?(held)
          raise ArgumentError, "background :#{name} has `held: #{held.inspect}`. `held:` must be true or false."
        end
        return unless held && @screen_mode == :bitmap

        raise ArgumentError,
              "background :#{name} has `held: true` on a `screen :bitmap`. On that screen, the framework paints " \
              "the background into the picture one time, so the background has no cells to change. To fix this, " \
              "remove `held: true`, or declare the background on a `screen :tiled`."
      end

      # One name declared in several scenes keeps its changes the same way in each: a line that
      # changes a cell names the background, not the scene.
      def refuse_held_differently!(name, declared, held)
        return if declared.node.nil? || declared.held == held

        raise ArgumentError,
              "The game declares background :#{name} in more than one scene, and only some of these declarations " \
              "have `held: true`. A `set_tile` line names the background, not the scene. To fix this, give " \
              "`held: true` to every declaration of :#{name}, or to none of them."
      end

      # The body of {#background}, and of {#status_bar}, which is a background with +bar_top+.
      def declare_background(name, tiles:, map: nil, from: nil, walls: nil, bar_top: nil, above_row: nil, alone: false,
                             held: false)
        refuse_background_in_game_loop!(name)
        if tiles.is_a?(Hash)
          set, map_names, drawn, tile_names, grids, sets, area_tiles = background_from_sets(name, tiles, map, from)
          img_rows = drawn.first.first
          index_of = {}
        else
          set = tileset!(name, tiles)
          map_names, drawn = background_maps(name, tiles, set, map: map, from: from)
          # The tile list comes from the TILESET rather than from the map, so every one of a
          # background's maps has the same one — which is what lets them share a numbering and
          # take turns in one grid.
          img_rows, tile_names = drawn.first

          # Number the distinct tiles, then turn each grid of tile images into a grid of
          # those numbers — nil where a cell is blank. The grid, not a pile of draw calls,
          # is what the background node carries, so a backend is free to stamp it pixel by
          # pixel or hand it to tile hardware.
          index_of = tile_names.each_with_index.to_h
          grids = drawn.map { |rows, _| rows.map { |row| row.map { |img| img && index_of[img] } } }
          sets = nil
        end
        streams = IR::TileMap.streams?(grids)

        # The line that makes the record every later fact about this background is written
        # into. The node is kept in it so `.rotate!`/`.scale`, which come later on the
        # handle, can mark this one as the layer that turns — see #make_background_affine.
        #
        # A record already there is kept and given the new node, never replaced: a program
        # that declares one name twice has already set things on the first one, and a
        # fresh record would drop them — a scroll it forgot would stop being moved to the
        # gap between frames and would tear where the author wrote it.
        refuse_name_in_two_places!(name, @backgrounds[name]) if @backgrounds[name]
        declared = (@backgrounds[name] ||= DeclaredBackground.new)
        refuse_held_differently!(name, declared, held)
        declared.held = held
        # Which map the game sets as showing, and which one is really in the cells — and, for
        # a background drawn from several sets of tiles, which set is really in tile memory.
        choice = map_names.size > 1 ? [:"__bg_#{name}_map", IR::Nodes::Background.map_in_cells_var(name)] : []
        choice += [IR::Nodes::Background.set_var(name)] if sets
        # ...and, for one brought into view a strip at a time, which map the strips come from:
        # back to the first with the rest. Not whether the cells around the view hold it yet.
        # A scene taking over fills the view itself, round the first map's corner, before
        # these are put back, so putting that one back to "nothing copied" afterwards would
        # have the gap between frames fill the whole view again for the same picture.
        choice += [IR::Nodes::Background.stream_vars(name).first] if streams
        refuse_streaming_turning_background!(name) if streams && @screen_mode == :rotozoom
        declared.node =
          record(Build.background(name, tiles: tile_names, map: grids.first,
                                        maps: map_names.size > 1 ? grids : [], choice: choice,
                                        tile_w: set[:tile_w], tile_h: set[:tile_h],
                                        scene: declaring_scene, bar_top: bar_top, above_row: above_row,
                                        alone: alone != false, hides_sprites: alone == :without_sprites,
                                        affine: @screen_mode == :rotozoom, **(sets || {})))
        # Which scene this background belongs to, so that everything written for it each
        # frame is written only while that scene is the live one. Where a background sits
        # is a property of the console's layer rather than of the background, and scenes
        # take turns with the layers — so two backgrounds that share one would both write
        # its position every frame, and whichever was declared later would win.
        #
        # A name declared in several scenes belongs to each of them, and is written for while
        # any of them is up. A declaration outside every scene (a nil gate) is there in all of
        # them.
        declared.scene_gates = (declared.scene_gates || []) | [@current_scene_gate]

        # The window's top-left, in pixels, tracked in two hidden variables (cleared at
        # boot since console RAM isn't zero at power-on). A background that never
        # scrolls simply leaves them at 0.
        scroll_x, scroll_y = IR::Nodes::Background.scroll_vars(name)
        boot = [scroll_x, scroll_y]
        # ...and, for a background with several maps, which one the game sets as showing and
        # which one is really in its cells. Both start at 0 — the first map, the one the
        # build already stamped — so nothing is copied until the game asks for another. A
        # background brought into view a strip at a time starts with nothing in its cells, too.
        boot += choice
        boot += [IR::Nodes::Background.stream_vars(name).last] if streams
        boot.each { |var| at_boot(Build.set(var, Build.int(0))); ensure_var(var) }
        # The cells around the view are brought in where the view's place is written, in
        # the gap between frames — so one that never scrolls still has that write.
        if streams
          declared.scroll_x = scroll_x
          declared.scroll_y = scroll_y
        end
        # Kept for the check, once the whole program is declared, that a background with tiles drawn
        # from a list the game changes was told to follow it (ColorLists#link_backgrounds_to_changing_lists).
        @background_handles << DSL::Background.new(self, name: name, scroll_x: scroll_x, scroll_y: scroll_y,
                             walls: wall_rects(img_rows, set),
                             # The biggest map's size each way, which is every map's where they
                             # are one size. The walls of each map are laid out at this size, so
                             # finding a map's walls stays arithmetic when the maps differ.
                             cells: [grids.map { |grid| grid.map(&:length).max || 0 }.max, grids.map(&:length).max],
                             streams: streams,
                             tile_index: tile_lookup(set, index_of),
                             bitmap: @screen_mode == :bitmap,
                             map_names: map_names,
                             node: declared.node,
                             # One grid of walls per map, in the order they were declared —
                             # so a mover is stopped by the walls of the room it is in
                             # rather than by the first room's, wherever it stands.
                             solid_cells: wall_grids(name, map_names, drawn, set, walls),
                             # ...and which tiles are walls, so a cell set_tile changes takes
                             # its tile's: walls written apart with `walls:` set nothing about tiles.
                             solid_tiles: walls.nil? && !tiles.is_a?(Hash) ? solid_tile_numbers(tile_names, set) : nil,
                             tile_size: [set[:tile_w], set[:tile_h]],
                             # Areas, though all of one set of tiles (#background_from_sets).
                             walks_areas: tiles.is_a?(Hash),
                             # ...and each area's keys, so set_tile names a tile of the area showing.
                             area_tiles: area_tiles,
                             held: held,
                             tile_pictures: tiles.is_a?(Hash) ? tile_names.uniq : (set[:by_key].values + set[:by_number].values).uniq)
        @background_handles.last
      end

      public

      # Make a background able to turn and resize as a whole (see {Background#rotate} /
      # {Background#scale}): mark it as the layer that turns, allocate its angle and size
      # variables, boot them to upright and 1.0, and remember it needs its matrix written
      # every frame. Idempotent — the first call wires it up, later ones reuse the same
      # variables. An internal hook, not a DSL verb — `background(...).rotate!` /
      # `.scale` are the surface.
      #
      # Turning is a property of the background, not of the screen, and that is the whole
      # reason this hook exists rather than a flag on `background`. The console has two
      # arrangements of tile layers that matter here: four layers that scroll and none
      # that turn, or two that scroll plus one that turns and resizes. Which one a game
      # needs is decided by whether it ever turns a background — which is exactly this
      # call — so nothing in a program ever names an arrangement. A background declared
      # under `screen :rotozoom` is already one that turns (that screen has no other
      # kind), so this only ever adds one.
      #
      # `screen :bitmap` has no background layer at all, only pixels you draw, so there is
      # nothing there to turn.
      # Hook a background handle calls to make the layer turn; documented on `background`.
      def make_background_affine(name)  # :nodoc:
        background = declared_background(name)
        return [background.angle, background.scale] if background.turns_each_frame?

        refuse_changed_name_in_two_scenes!(name, "turns or resizes") if background.scene_gates.length > 1
        refuse_turning_without_tile_screen!(name)
        refuse_streaming_turning_background!(name) if background.node.streams?
        refuse_turning_scrolled_background!(name)
        refuse_turning_recolored_background!(name)

        background.node.affine = true
        angle_var = :"__bg_#{name}_angle"
        scale_var = :"__bg_#{name}_scale"
        at_boot(Build.set(angle_var, Build.int(0)))
        ensure_var(angle_var)
        var(scale_var, 1.0)
        defer_affine_write(name, angle_var, scale_var)
        [angle_var, scale_var]
      end

      # Record a background's per-row bend (see {Background#scroll_each_row}). The block
      # is handed the row as a {Value} and gives back the sideways offset for it; anything
      # else the block records runs first, in the same place.
      #
      # An internal hook, not a DSL verb — `background(...).scroll_each_row { }` is the
      # surface.
      # Hook behind Background#scroll_each_row, documented on `background`.
      def record_row_bend(name, row_var, &block)  # :nodoc:
        unless @screen_mode == :tiled
          raise ArgumentError,
                "#{name}.scroll_each_row bends a tiled background row by row, so it needs a " \
                "`screen :tiled`. A bitmap screen has no background layer to bend — it has pixels you " \
                "draw. To bend a picture there, draw each row where you want it with `draw_rect_at` " \
                "or `blit`."
        end

        # A bend gives each row its own sideways scroll, and a layer that turns has no
        # scroll to give — it moves by turning. Before a tiled background could turn, the
        # screen check above already covered this; now it has to be said.
        if declared_background(name).turns_each_frame?
          raise ArgumentError,
                "#{name}.scroll_each_row bends a background row by row, and background :#{name} turns " \
                "and resizes. A layer that turns has no scroll to bend. To fix this, bend a different " \
                "background, or stop turning :#{name}."
        end
        # A map brought into view a strip at a time holds only the columns around the view, and
        # a bent row reaches past them into columns nobody brought in.
        if declared_background(name).node.streams?
          raise ArgumentError,
                "#{name}.scroll_each_row bends a background row by row, and background :#{name} has a map " \
                "bigger than 64x64 cells, or maps that are not all one size. Such a background holds only " \
                "the cells around the view, and a bent row can show cells outside them. To fix this, bend " \
                "a different background, or make every map of :#{name} one size, 64x64 cells or smaller."
        end
        if declared_background(name).scene_gates.length > 1
          refuse_changed_name_in_two_scenes!(name, "bends its rows with `scroll_each_row`")
        end
        declared_background(name).bends_rows = true # ...and the other order: turning it later is refused too

        ensure_var(row_var)
        node = Build.scroll_rows(name, row: row_var, offset: Build.int(0))
        offset = nil
        # The row is handed over, and a bend the same on every row never reads it.
        push_container(node) { offset = block.call(DSL::Value.handed_to_block(self, Build.var_ref(row_var))) }
        node.offset = DSL::Value.node_for(offset)
        node
      end

      private

      # Where each background keeps its state, for reading it back by its name
      # (Program#background_readings). A name declared in several scenes is one background.
      def finalize_background_readings
        readings = @background_handles.map(&:reading).uniq(&:name)
        @program.background_readings = readings unless readings.empty?
      end

      # A layer that turns cannot also scroll, and a program can write the two in either
      # order. Turning first and scrolling second is refused where the scroll is written
      # (see {Background#ensure_not_affine!}); this is the other order, where the scroll
      # is already recorded and turning the layer would quietly stop it working — the
      # console pans this kind of layer by moving its whole matrix, and its own scroll
      # registers do nothing at all.
      # A layer that turns cannot also be given other colours, and the reason is where its
      # colours are kept. A scrolling layer's cells each name a group of sixteen colours to
      # draw from, and giving the layer another list means writing that group. A turning
      # layer's cells hold a tile number and nothing else, so its tiles read the whole table
      # instead — there is no group of its own to write, and writing the table would recolour
      # everything on screen.
      def refuse_coloring_turning_background!(name)
        return unless background_turns?(name)

        raise ArgumentError,
              "This program turns or resizes background :#{name}, so :#{name} cannot also draw with " \
              "other colors. A layer that turns reads all the colors in the game, not a list of its " \
              "own. To fix this, give other colors to a background that does not turn."
      end

      def refuse_turning_recolored_background!(name)
        return unless declared_background(name).draws_with_colors?

        raise ArgumentError,
              "This program draws background :#{name} with other colors, so :#{name} cannot also turn " \
              "or resize. A layer that turns reads all the colors in the game, not a list of its own. " \
              "To fix this, turn a different background, or stop giving :#{name} other colors."
      end

      def refuse_turning_scrolled_background!(name)
        background = declared_background(name)
        moves = if background.scrolls? then "scrolls"
                elsif background.bends_rows? then "bends the rows of"
                end
        return unless moves

        raise ArgumentError,
              "This program #{moves} background :#{name}, so :#{name} cannot also turn or resize. " \
              "A layer that turns has no scroll of its own. It moves by turning instead. To fix " \
              "this, stop moving :#{name} that way, or turn a different background."
      end

      # Which screens can turn a background at all, said as a message. The two that draw
      # a background out of tiles can; a bitmap screen has no layer to turn, only pixels.
      #
      # A raw register value leaves the mode unnamed (see Drawing#screen), and so does a
      # program that never wrote `screen` — so neither can be quoted back, and neither
      # can be told what it holds.
      def refuse_turning_without_tile_screen!(name)
        return if IR::Modes::TILE_SCREENS.include?(@screen_mode)

        have = if @screen_mode
                 "You have `screen #{@screen_mode.inspect}`, which holds pixels you draw " \
                 "and has no background layer"
               else
                 "This program names neither screen"
               end
        raise ArgumentError,
              "#{name}.rotate! and #{name}.scale turn and resize the whole background. A background " \
              "can turn only on `screen :tiled` or `screen :rotozoom`. #{have}. To fix this, write " \
              "`screen :tiled` above this background."
      end

      # Which of a background's own tiles each key means, so `set_tile` can be written
      # the way the map was — the tileset's own keys, or, for a sheet imported as
      # numbered tiles, those numbers. Every tile of the tileset is shipped whether the
      # map used it or not, so a door can be drawn in the tileset and only ever appear
      # once something opens it.
      def tile_lookup(set, index_of)
        named = set[:by_key].empty? ? (set[:by_number] || {}) : set[:by_key]
        named.to_h { |key, image| [key, index_of[image]] }.compact
      end

      # Import a tileset from a sheet by character: slice the file into cells of the
      # given size and define the cell each character points at as an image, returning
      # the character => image-name map the tileset is built from. Each character's
      # value is a cell number or [column, row]. The internal image names are unique
      # per tileset.
      def import_tile_cells(name, path, tile, transparent, cells)
        tile_w, tile_h = sheet_tile_size("tiles :#{name}", tile)
        sheet = Graphics::Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        cells.each_with_index.each_with_object({}) do |((char, where), idx), out|
          col, row = sheet_cell_at("tiles :#{name} tile #{char.inspect}", where, sheet.cols)
          bmp = sheet.cell(col, row)
          img = :"__tile_#{name}_#{idx}"
          define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data,
                                  transparent: bmp.transparent)
          out[char] = img
        end
      end

      # Import a whole tile sheet as numbered tiles: slice the file into cells and make
      # cell (col, row) tile number `row*cols + col + 1` — 1-based, left-to-right then
      # top-to-bottom, the exact order a map editor like Tiled numbers a sheet (so its
      # CSV export lines up). `solid:` here is a list of those tile numbers. There are
      # no characters — a background over this tileset is authored as a CSV of numbers.
      def define_sheet_tileset(name, path, tile, transparent, solid_numbers, black)
        tile_w, tile_h = sheet_tile_size("tiles :#{name}", tile)
        sheet = Graphics::Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)

        by_number = {}
        sheet.rows.times do |row|
          sheet.cols.times do |col|
            number = (row * sheet.cols) + col + 1
            bmp = sheet.cell(col, row)
            img = :"__tile_#{name}_#{number}"
            define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data,
                                    transparent: bmp.transparent)
            by_number[number] = black == :solid ? solid_black_image(img) : img
          end
        end

        unknown = solid_numbers.reject { |n| by_number.key?(n) }
        unless unknown.empty?
          raise ArgumentError,
                "tiles :#{name}: solid #{unknown.map(&:inspect).join(', ')} " \
                "#{unknown.one? ? 'is' : 'are'} not a tile number in the sheet. " \
                "The sheet holds tiles #{by_number.keys.min}..#{by_number.keys.max}."
        end

        @tilesets[name] = { by_key: {}, by_number: by_number, tile_w: tile_w, tile_h: tile_h,
                            solid_images: solid_numbers.map { |n| by_number[n] }.uniq }
      end

      # Every map this background can show, as [names, drawn] — the names in the order they
      # were declared, and one [grid of tile-image names, tile list] per map.
      #
      # A background usually has one map and its name is the background's own. Give `map:`
      # or `from:` a hash instead and it has several, one showing at a time: name => map,
      # in the order written, the first being the one showing at boot.
      def background_maps(name, tiles, set, map:, from:)
        chars = map.is_a?(Hash)
        several = chars ? map : from
        return [[name], [background_image_grid(name, tiles, set, map: map, from: from)]] unless several.is_a?(Hash)

        raise ArgumentError, "background :#{name}: give it a map: or a from:, not both" if map && from
        raise ArgumentError, "background :#{name} was given no maps at all" if several.empty?

        drawn = several.map do |_, one|
          background_image_grid(name, tiles, set, map: chars ? one : nil, from: chars ? nil : one)
        end
        [several.keys, drawn]
      end

      def tileset!(name, tiles)
        @tilesets[tiles] || raise(ArgumentError,
                                  "background :#{name}: there is no tileset named :#{tiles}. " \
                                  "Define one first with `tiles :#{tiles}, ...`.")
      end

      # A background whose maps draw from several sets of tiles, which is how a game moves
      # between areas: `tiles:` names each set by the area it belongs to, and `map:` gives
      # each area's maps under the same name. The maps are counted in the order written,
      # area after area, which is the number `show_map` takes.
      #
      # Returns what #background works with: a tileset standing for every set at once (for
      # the walls, read off pictures, and the tile size), the map names, each map's grid of
      # pictures, every set's tiles one after another, each map as numbers into those, and
      # the three operands that hold which tiles and maps belong to which set.
      #
      # Areas of the same tiles are one set. Two areas whose tilesets hold the same pictures
      # (one tileset named for both, or a data pack's areas over one slot of tiles) are one
      # set, named for the first of them, and each area's maps number into it. A walk between
      # them then hands the layer another map and nothing else: no tiles come in, so no frame
      # is spent with the layers off. A console's own games keep several maps over one stretch
      # of tiles in video memory and point the layer at another (GBATEK, "LCD I/O BG Control":
      # a layer's tiles and its map are chosen apart). Where every area is of one set the
      # background walks between no sets at all, and its maps take turns in one grid as any
      # background's several maps do; the third operand is then nil.
      def background_from_sets(name, tiles, map, from)
        refuse_tile_sets_shape!(name, tiles, map, from)
        sets = tiles.transform_values { |tileset| tileset!(name, tileset) }
        refuse_tile_sets_of_two_sizes!(name, tiles, sets)

        map_names = []
        drawn = []
        grids = []
        tile_names = []
        set_names = []
        set_starts = []
        map_sets = []
        set_of_tiles = {}
        area_tiles_by_key = []
        tiles.each_key do |area|
          names, area_drawn = background_maps(name, tiles[area], sets[area], map: map[area], from: nil)
          area_drawn = [area_drawn.first] if names == [name] # one map given as a grid, not a Hash
          names = [area] if names == [name]
          area_tiles = area_drawn.first.last
          number = set_of_tiles.fetch(area_tiles) do
            set_names << area
            set_starts << tile_names.length
            tile_names.concat(area_tiles)
            set_of_tiles[area_tiles] = set_names.length - 1
          end
          start = set_starts[number]
          index_of = area_tiles.each_with_index.to_h { |image, i| [image, start + i] }
          area_drawn.each do |rows, _|
            grids << rows.map { |row| row.map { |img| img && index_of[img] } }
            map_sets << number
          end
          area_tiles_by_key << DSL::Background::AreaTiles.new(tile_index: tile_lookup(sets[area], index_of),
                                                              maps: map_names.length...(map_names.length + names.length))
          map_names.concat(names)
          drawn.concat(area_drawn)
        end
        refuse_map_named_twice!(name, map_names)

        every = sets.values
        merged = { by_key: {}, by_number: {}, tile_w: every.first[:tile_w], tile_h: every.first[:tile_h],
                   solid_images: every.flat_map { |set| set[:solid_images] || [] }.uniq }
        walked = { sets: set_names, set_starts: set_starts, map_sets: map_sets } unless set_names.one?
        [merged, map_names, drawn, tile_names, grids, walked, area_tiles_by_key]
      end

      def refuse_tile_sets_shape!(name, tiles, map, from)
        if from
          raise ArgumentError,
                "background :#{name} walks between areas, so it cannot take from:. Give the maps of each area " \
                "with map:, under the same names as tiles:, like map: { #{tiles.keys.first}: { room: ... } }."
        end
        return if map.is_a?(Hash) && map.keys == tiles.keys

        raise ArgumentError,
              "background :#{name} walks between the areas #{tiles.keys.map(&:inspect).join(', ')}. map: must " \
              "give the maps of each area under the same names, in the same order, like " \
              "map: { #{tiles.keys.first}: { room: ... } }."
      end

      def refuse_tile_sets_of_two_sizes!(name, tiles, sets)
        sizes = sets.transform_values { |set| [set[:tile_w], set[:tile_h]] }
        return if sizes.values.uniq.size == 1

        first, other = sizes.keys.first, sizes.keys.find { |area| sizes[area] != sizes.values.first }
        raise ArgumentError,
              "background :#{name}: the tiles of the area :#{first} (tileset :#{tiles[first]}) are " \
              "#{sizes[first].join('x')}, and the tiles of the area :#{other} (tileset :#{tiles[other]}) are " \
              "#{sizes[other].join('x')}. All the areas of one background must have tiles of one size."
      end

      def refuse_map_named_twice!(name, map_names)
        twice = map_names.tally.find { |_, count| count > 1 }&.first
        return unless twice

        raise ArgumentError,
              "background :#{name} has two maps named #{twice.inspect}. show_map finds a map by its name, so " \
              "each map must have a name of its own, in every area."
      end

      # A layer that turns holds its whole map at once. Its cells are read through the turn,
      # so any of them can come into view on any frame, and there is no edge of the view to
      # bring a strip in at. So a map too big for its grid, or maps of different sizes, cannot
      # be a turning background's.
      def refuse_streaming_turning_background!(name)
        turns = @screen_mode == :rotozoom ? "is on `screen :rotozoom`, where a background turns," : "turns or resizes,"
        raise ArgumentError,
              "background :#{name} #{turns} and its maps are bigger than 64x64 cells or are not all one " \
              "size. A background that turns must hold its whole map at once. To fix this, make every map " \
              "of :#{name} one size, 64x64 cells or smaller, or use a background that does not turn."
      end

      # A background on a layer is declared once. The console draws a layer every frame from
      # the moment its tiles and map are in video memory, so a tiled background belongs above
      # the game loop or in a scene, which is built once off the loop. Put up again on every
      # pass of the loop, it reaches the screen at a different moment on each backend, and the
      # two draw different pictures.
      #
      # The rule is the loop's body and nothing wider. Tiled text is refused in any routine as
      # well, but a background declared in a routine the loop calls draws the same picture on
      # both backends, for a small map and for one bigger than the console's grid, so there is
      # no mistake there to stop. A bitmap background is painted into the picture
      # where it is written, as `blit` is, so the loop is no mistake for one either.
      def refuse_background_in_game_loop!(name)
        return unless IR::Modes::TILE_SCREENS.include?(@screen_mode)
        return unless @container_stack.any? { |open| open.kind == :loop }

        raise ArgumentError,
              "Declare background :#{name} once, above your game_loop or inside a scene. Do not declare it " \
              "inside the loop. On a tiled screen, the console draws a background every frame after you " \
              "declare it once. To show another map from the loop, use show_map."
      end

      # The background's cells as a grid of tile-image names (nil = blank), plus the
      # list of distinct tile images in a stable order. Author the grid with `map:` (a
      # grid of tileset keys) or `from:` (a CSV tilemap of tile numbers) — one or the
      # other, never both.
      def background_image_grid(name, tiles, set, map:, from:)
        if from
          raise ArgumentError, "background :#{name}: give it a map: or a from:, not both" if map

          csv_image_grid(name, tiles, set, from)
        elsif map
          keyed_image_grid(name, tiles, set, map)
        else
          raise ArgumentError,
                "background :#{name} needs a map: (a grid of tile keys) or a from: (a CSV tilemap file)"
        end
      end

      # Turn a `map:` into a grid of tile-image names. Its cells are whatever the
      # tileset is keyed by, and a row writes them one of two ways: as a String, one
      # character per cell, or as an Array, one element per cell. The two are the same
      # grid — a String row is the typed-out form, and it can only reach a tileset whose
      # keys are single characters, which is why the Array form exists at all. A level
      # the build works out (decoded from somewhere, generated) has a tile number per
      # cell and was never characters, and there are more distinct tiles in a real
      # screenful than anybody would type as an alphabet.
      #
      # The blank cell — leave the background showing through — is a space in a String
      # row and nil in an Array row. (It is `0` in a CSV, whose numbering starts at 1;
      # that convention belongs to the editors that export one, so it stays in
      # csv_image_grid rather than becoming a rule here.)
      def keyed_image_grid(name, tiles, set, map)
        rows = background_rows(name, map) # shape first: an empty or ragged map is that mistake, not this one
        by_key = tiles_by_key(name, tiles, set, rows)

        img_rows = rows.map do |row|
          row.map do |cell|
            next nil if cell.nil? || cell == " "

            by_key[cell] || raise(ArgumentError,
                                  "background :#{name}: #{cell.inspect} is not in tileset :#{tiles}. " \
                                  "#{tileset_tiles_in_words(by_key.keys)}")
          end
        end
        [img_rows, by_key.values.uniq]
      end

      # Which tiles a tileset has, said in an error. A tileset somebody wrote out has a
      # handful of keys and naming them all is the whole answer — you can see at a glance
      # which one you meant. One a level was computed against can have hundreds, and
      # listing those buries the single fact the reader came for under a wall of numbers.
      # So past a size nobody would read, say how many there are and where they start and
      # end, which is what tells somebody whether their key was even in the right range.
      TILE_KEYS_TO_NAME = 24  # :nodoc:

      # What a tileset can set about black drawn by colour (#tiles).
      BLACK_ANSWERS = %i[see_through solid].freeze  # :nodoc:

      def tileset_tiles_in_words(keys)
        return "Its tiles are #{keys.map(&:inspect).join(', ')}." if keys.length <= TILE_KEYS_TO_NAME

        first = keys.first(3).map(&:inspect).join(", ")
        last = keys.last(3).map(&:inspect).join(", ")
        "It has #{keys.length} tiles. The first are #{first} and the last are #{last}."
      end

      # What a `map:` cell selects by. A tileset written out by hand is keyed by whatever
      # its author wrote — characters, or tile numbers; one imported whole from a sheet
      # has no keys of its own, and its keys are the numbers the sheet was sliced into.
      #
      # A character map over that second kind is the one combination with no answer, and
      # it is worth its own error: the characters it is written in mean nothing there, so
      # every cell would be wrong rather than one of them.
      def tiles_by_key(name, tiles, set, rows)
        by_key = set[:by_key]
        return by_key unless by_key.empty?

        if character_map?(rows)
          raise ArgumentError,
                "background :#{name}: tileset :#{tiles} was imported as numbered tiles, so it has no characters. " \
                "A character map: cannot select its tiles. " \
                "Write the map as rows of its tile numbers, or give from: a CSV file."
        end
        set[:by_number]
      end

      # A map written as characters, judged on the cells rather than on the shape it
      # arrived in — because the same mistake can be written either way. A block of text
      # and rows of single-character strings are the same map, and so is an Array whose
      # cells happen to be single characters, which is what somebody reaches for first
      # after learning that a row may be an Array.
      #
      # Blanks do not count either way (they are a blank in any map), so a map of nothing
      # but blanks is not characters — there is no character in it to have meant anything.
      def character_map?(rows)
        cells = rows.flatten(1).reject { |cell| cell.nil? || cell == " " }
        !cells.empty? && cells.all? { |cell| cell.is_a?(String) && cell.length == 1 }
      end

      # Turn a CSV tilemap (a grid of tile numbers) into a grid of tile-image names. A
      # `0` is a blank cell; any other number picks a tile by the tileset's numbering.
      def csv_image_grid(name, tiles, set, path)
        by_number = set[:by_number]
        numbers = parse_csv_tilemap(name, File.read(resolve_asset_path(path)))

        img_rows = numbers.map do |row|
          row.map do |n|
            next nil if n.zero? # 0 = an empty cell (a map editor's convention) — background shows through

            by_number[n] || raise(ArgumentError,
                                  "background :#{name}: the map uses tile number #{n}, but tileset :#{tiles} " \
                                  "has only tiles #{by_number.keys.min}..#{by_number.keys.max}. " \
                                  "Make sure this CSV is from the same tile sheet.")
          end
        end
        [img_rows, by_number.keys.sort.map { |k| by_number[k] }.uniq]
      end

      # Parse a CSV tilemap, as a map editor like Tiled exports a layer: rows of
      # comma-separated whole numbers, one row per line. Blank lines and a trailing
      # comma on a row are tolerated. Every row must be the same width (a map is a
      # rectangle) and every cell a number (0 = empty). The high bits a map editor sets
      # on a flipped/rotated tile are stripped, so such a tile still draws (unflipped)
      # rather than erroring.
      def parse_csv_tilemap(name, text)
        rows = text.each_line.map(&:strip).reject(&:empty?).each_with_index.map do |line, r|
          line.split(",").map(&:strip).reject(&:empty?).map do |field|
            unless field.match?(/\A\d+\z/)
              raise ArgumentError,
                    "background :#{name}: the tilemap must be a grid of numbers (a CSV export), " \
                    "but line #{r + 1} has #{field.inspect}."
            end
            field.to_i & 0x1FFFFFFF # drop a map editor's tile-flip flags (the top 3 bits of the number)
          end
        end
        raise ArgumentError, "background :#{name}: the tilemap file is empty" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "background :#{name}: the tilemap has rows of different widths (#{widths.sort.join(', ')} cells). " \
                "Every row must be the same length, because a map is a rectangle."
        end
        rows
      end

      # The wall rectangles for a background: the cells whose tile is marked `solid:` in
      # the tileset, merged into as few rectangles as possible and given in pixels. A
      # sprite `blocked_by` this background is stopped from entering any of them. Merging
      # keeps the count small — a bordered room is four rectangles, not one per wall tile
      # — so the per-frame overlap tests stay cheap. +img_rows+ is the grid of tile-image
      # names (nil = blank cell) the background was built from.
      def wall_rects(img_rows, set)
        grid = solid_cell_grid(img_rows, set)
        return [] if grid.nil?

        merge_solid_cells(grid).map do |col, row, w, h|
          [col * set[:tile_w], row * set[:tile_h], w * set[:tile_w], h * set[:tile_h]]
        end
      end

      # Which cells are walls, as the grid it already is rather than as rectangles.
      #
      # This is the same answer #wall_rects starts from, kept in its own shape because the
      # two are wanted for different things. Rectangles are what a person reads and what a
      # box test wants; the grid is what a mover wants, because asking "is the cell I am
      # stepping into a wall" costs the same whatever the room looks like, where testing
      # every rectangle costs what the room is made of. See Background#solid_lookup.
      #
      # nil, not [], when the tileset marks nothing solid — there is no grid to consult and
      # a mover blocked by this background is not blocked by anything.
      # The numbers of a tileset's tiles marked `solid:`, as a map numbers its cells.
      def solid_tile_numbers(tile_names, set)
        tile_names.each_index.select { |index| set[:solid_images].include?(tile_names[index]) }
      end

      def solid_cell_grid(img_rows, set)
        solid = set[:solid_images]
        return nil if solid.empty?

        img_rows.map { |row| row.map { |img| !img.nil? && solid.include?(img) } }
      end

      # Every map's walls, one grid per map in the order they were declared.
      #
      # With no `walls:` they come off the picture — the cells whose tile the tileset
      # marked `solid:` — which is what a small game wants and what every game wrote
      # before `walls:` existed. With `walls:` they are their own data, given apart from
      # the picture, and a map `walls:` does not name has none at all.
      def wall_grids(name, map_names, drawn, set, walls)
        return drawn.map { |rows, _| solid_cell_grid(rows, set) } if walls.nil?

        given = walls.is_a?(Hash) ? walls : { map_names.first => walls }
        check_walls_name_maps!(name, map_names, given)
        map_names.map { |map_name| wall_grid(given[map_name]) }
      end

      # One `walls:` grid as cells of true/false. A cell is a wall unless it is blank, and
      # blank is a space, a `.`, a `0` or nothing — so a grid drawn by hand and a collision
      # layer decoded out of somewhere else are both read the same way, with no list of
      # which values mean which to keep in step with the data.
      BLANK_WALL_CELLS = [nil, 0, "0", ".", " ", ""].freeze  # :nodoc:

      def wall_grid(rows)
        return nil if rows.nil?

        rows = rows.lines.map(&:chomp) if rows.is_a?(String)
        rows.map do |row|
          cells = row.is_a?(String) ? row.chars : row
          cells.map { |cell| !BLANK_WALL_CELLS.include?(cell) }
        end
      end

      # `walls:` keyed by a map the background does not have is almost always a name spelled
      # two ways, and it would silently leave that room with no walls at all — which reads
      # as "the collision is broken in this one room" rather than as a typo.
      def check_walls_name_maps!(name, map_names, given)
        unknown = given.keys - map_names
        return if unknown.empty?

        raise ArgumentError,
              "background :#{name} has no map #{unknown.map(&:inspect).join(', ')}, so `walls:` " \
              "cannot say where its walls are. Its maps are #{map_names.map(&:inspect).join(', ')}. " \
              "A map that `walls:` does not name has no walls, so a misspelled name here is a " \
              "room you can walk straight through."
      end

      # Greedily cover the solid cells with rectangles: from each unclaimed solid cell,
      # grow right as far as the run goes, then down as far as that whole width stays
      # solid, claim the block, and move on. Maze-shaped walls collapse to a handful of
      # rectangles this way. Returns [col, row, width, height] in tile units.
      def merge_solid_cells(grid)
        rows = grid.length
        cols = grid.map(&:length).max || 0
        claimed = Array.new(rows) { Array.new(cols, false) }
        rects = []
        rows.times do |r|
          cols.times do |c|
            next unless grid[r][c] && !claimed[r][c]

            w = 1
            w += 1 while c + w < cols && grid[r][c + w] && !claimed[r][c + w]
            h = 1
            h += 1 while r + h < rows && (c...c + w).all? { |cc| grid[r + h][cc] && !claimed[r + h][cc] }
            (r...r + h).each { |rr| (c...c + w).each { |cc| claimed[rr][cc] = true } }
            rects << [c, r, w, h]
          end
        end
        rects
      end

      # Normalize a background map into a grid of cells, whatever shape it was written
      # in: a block of text is split on newlines (blank lines dropped) and each line
      # into its characters; an Array is its rows already, and a row that is a String is
      # split the same way while a row that is an Array is its cells already. So the
      # rest of the build sees one thing — a grid — and never asks which form it came
      # in as.
      #
      # A map is a rectangle, so every row must be the same width. A ragged one is
      # almost always a typo (a stray or missing cell), and left alone it would push
      # part of the level out of line, so we catch it with a plain-language error.
      def background_rows(name, map)
        rows = case map
               when String then map.each_line.map(&:chomp).reject(&:empty?)
               when Array then map
               else raise ArgumentError,
                          "background :#{name}: the map must be a String or an Array of rows."
               end
        rows = rows.map do |row|
          case row
          when String then row.chars
          when Array then row
          else raise ArgumentError,
                     "background :#{name}: every row of a map must be a String or an Array. " \
                     "This row is #{row.inspect}."
          end
        end
        # Rows with no cells in them are an empty map too: the Genesis copies a map a row at a
        # time, and a row of no cells counted down from nought as the most its counter holds.
        raise ArgumentError, "background :#{name} has an empty map" if rows.empty? || rows.all?(&:empty?)

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "background :#{name} has rows of different widths (#{widths.sort.join(', ')} cells). " \
                "Every row must be the same length, because a map is a rectangle."
        end
        rows
      end
    end
  end
end
