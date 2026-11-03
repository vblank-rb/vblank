# frozen_string_literal: true

module VBlank
  class Builder
    # A SET OF SPRITE TILES THE GAME LOADS AS IT RUNS, and the poses drawn from it.
    #
    #   ball_tiles = sprite_tiles :ball_tiles, count: 32, colors: :ball
    #   image :spin0, tiles_from: :ball_tiles, pieces: [[0, 0, 0], [8, 0, 1], [0, 8, 2], [8, 8, 3]]
    #   sprite :ball, at: [80, 60], frames: %i[spin0 spin1], rate: 4
    #   ball_tiles.copy_from :great_ball, at: 0, count: 3, to: 9
    #
    # A sprite usually keeps its own tiles for each pose, and a pose that shares a tile with
    # another keeps a copy. Retail games often do it the other way round: the console's sprite
    # memory holds a few tiles the game rewrites, and every pose of the sprite points at some of
    # them. The ball of a pinball game spins through eight poses drawn from 32 tiles, and turning
    # it into another kind of ball rewrites those 32 tiles, a few at a time, from the cartridge.
    # Every pose then shows the new ball with nothing else changed, and the poses take no room of
    # their own however many kinds of ball the cartridge holds.
    #
    # The set is that room, and a pose is a picture made of its tiles. Loading tiles of the set
    # changes every pose that draws them from the next frame on, as a painted picture's
    # `changed` does. On a console whose sprites point at tiles, a pose is only which tiles and
    # where, so showing another pose is what `face` always costs and a load copies the tiles it
    # names and nothing else. A build that draws each pose as a picture of its own writes the
    # loaded tiles into each pose that draws them.
    module SpriteTiles
      # Bytes one tile of a load's source takes: 8 rows of 8 pixels, two pixels a byte, as painted
      # tiles keep them (Builder::TileRuns::TILE_BYTES).
      TILE_BYTES = 32

      # The most tiles one set holds. A Game Boy Color keeps a sprite's tiles in sides of 128,
      # and a set lives in one of them, so its loads are one copy each.
      MOST_TILES = 128

      # A set of +count+ tiles of 8×8 in sprite memory, drawn from +colors+ by place (place 0
      # see-through), each see-through until the game loads it. Returns the handle the game
      # loads tiles through (DSL::SpriteTileSet).
      def sprite_tiles(name, count:, colors:)
        refuse_sprite_tiles_name_taken!(name)
        refuse_bad_sprite_tiles_count!(name, count)
        refuse_sprite_tiles_on_bitmap_screen!(name)
        list = tile_run_colors(name, colors, what: "sprite_tiles")
        colors_name = colors if colors.is_a?(Symbol)
        @sprite_tile_sets[name] = { count: count, colors: list, colors_name: colors_name }
        record(Build.sprite_tiles(name, count: count, colors: list, colors_name: colors_name))
        DSL::SpriteTileSet.new(self, name)
      end

      # The set +name+'s tiles from +to+ on take +count+ tiles of +source+ from its tile +at+ on,
      # in the picture of this pass (DSL::SpriteTileSet#copy_from).
      def load_sprite_tiles(name, source, at:, count:, to:)
        set = @sprite_tile_sets.fetch(name)
        unless count.is_a?(Integer) && count.between?(1, set[:count])
          raise ArgumentError, "sprite_tiles :#{name} was told to copy #{count.inspect} tiles. Give count: a whole " \
                               "number from 1 to #{set[:count]}, the tiles the set holds."
        end
        table = sprite_tiles_source(name, set, source)
        record(Build.load_sprite_tiles(name, table: table, at: DSL::Value.node_for(at), to: DSL::Value.node_for(to),
                                             count: count))
        ensure_var(at)
        ensure_var(to)
      end

      private

      # `image :spin0, tiles_from: :ball_tiles, pieces: [[dx, dy, tile], ...]`: a pose drawn from
      # tiles of a set. Each piece is where the tile's top left goes in the picture, on its
      # 8-pixel grid, and which tile of the set, counting from 0.
      def define_tile_pose(name, opts)
        set_name = opts[:tiles_from]
        set = @sprite_tile_sets[set_name]
        unless set
          raise ArgumentError, "image :#{name} gets its tiles from :#{set_name.inspect.delete_prefix(':')}, and no " \
                               "sprite_tiles has that name. Declare the set first with " \
                               "`sprite_tiles :#{set_name}, count: ..., colors: ...`."
        end
        extra = opts.keys - %i[tiles_from pieces]
        unless extra.empty?
          raise ArgumentError, "image :#{name} gets its tiles from :#{set_name}, so its pixels and its colours are " \
                               "the set's. It was also given #{extra.map { |key| "#{key}:" }.join(', ')}. Give " \
                               "tiles_from: and pieces: alone."
        end
        pieces = opts[:pieces]
        refuse_bad_tile_pose_pieces!(name, set_name, set[:count], pieces)
        width = pieces.map { |dx, _, _| dx + 8 }.max
        height = pieces.map { |_, dy, _| dy + 8 }.max
        @images[name] = [width, height]
        @tile_pose_sets[name] = set_name
        @painted_colors[name] = set[:colors]
        @painted_colors_names[name] = set[:colors_name]
        record(Build.tile_pose(name, tiles: set_name, pieces: pieces.map(&:dup), width: width, height: height))
        name
      end

      # The table a load reads +source+ from: a picture's tiles kept the way painted tiles are,
      # made once for each picture, or a table of bytes the game wrote itself.
      def sprite_tiles_source(name, set, source)
        return sprite_tiles_table_source(name, source) if source.is_a?(DSL::Table)

        picture = source.is_a?(Symbol) && @pictures[source]
        unless picture
          raise ArgumentError, "sprite_tiles :#{name} was told to copy from #{source.inspect}. Give the name of an " \
                               "image, or a table of bytes."
        end
        table_name = Messages::MadeNames.make(:sprite_tiles_source, picture: source)
        return table_name if (@sprite_tile_sources ||= {})[table_name]

        bytes = sprite_tiles_picture_bytes(name, set, source, picture)
        at_boot(Build.table(table_name, bytes, width: :byte, signed: false))
        @sprite_tile_sources[table_name] = true
        table_name
      end

      def sprite_tiles_table_source(name, table)
        return table.name if table.width == :byte

        raise ArgumentError, "sprite_tiles :#{name} was told to copy from table :#{table.name}, which does not " \
                             "hold bytes. To fix this, declare it with `width: :byte`, #{TILE_BYTES} bytes a tile."
      end

      # A picture's tiles in the order a load counts them — left to right, then top to bottom —
      # each as painted tiles keep one: 32 bytes, eight rows of four, two places a byte, the left
      # one in the low four bits.
      def sprite_tiles_picture_bytes(name, set, source, picture)
        unless (picture.width % 8).zero? && (picture.height % 8).zero?
          raise ArgumentError, "sprite_tiles :#{name} was told to copy from image :#{source}, which is " \
                               "#{picture.width}x#{picture.height}. A load copies whole tiles of 8x8. To fix this, " \
                               "make each side of the image a multiple of 8."
        end
        places = sprite_tiles_places(set, picture)
        unless places
          list = set[:colors_name] ? "colors: :#{set[:colors_name]}" : "the same colors: list"
          raise ArgumentError, "sprite_tiles :#{name} was told to copy from image :#{source}, which is not drawn " \
                               "from the set's colours. To fix this, draw it with `image :#{source}, #{list}, ...`."
        end

        (0...picture.height).step(8).flat_map do |top|
          (0...picture.width).step(8).flat_map do |left|
            (0...8).flat_map do |row|
              places[((top + row) * picture.width) + left, 8].each_slice(2).map { |near, far| near | (far << 4) }
            end
          end
        end
      end

      # Each pixel of +picture+ as a place in the set's colours, or nil for a picture not drawn from
      # them. A picture given as places keeps them; one drawn as colours from the set's list (art
      # in characters, say) has each pixel's colour found in the list, place 0 for see-through.
      def sprite_tiles_places(set, picture)
        named = set[:colors_name] && picture.colors_name == set[:colors_name]
        return nil unless named || picture.colors == set[:colors]
        return picture.places.bytes if picture.places

        Array.new(picture.width * picture.height) do |at|
          next 0 unless picture.drawn_at?(at)

          (1...set[:colors].length).find { |place| set[:colors][place] == picture.raw_at(at) } or return nil
        end
      end

      def refuse_sprite_tiles_name_taken!(name)
        return unless @sprite_tile_sets.key?(name) || @images.key?(name)

        raise ArgumentError, "sprite_tiles :#{name} has the name of a set or a picture that is declared already. " \
                             "To fix this, give it a name of its own."
      end

      def refuse_bad_sprite_tiles_count!(name, count)
        return if count.is_a?(Integer) && count.between?(1, MOST_TILES)

        raise ArgumentError, "sprite_tiles :#{name} needs `count:`, how many tiles it holds. It must be a whole " \
                             "number from 1 to #{MOST_TILES}. Got #{count.inspect}."
      end

      def refuse_sprite_tiles_on_bitmap_screen!(name)
        return unless @screen_mode == :bitmap

        raise ArgumentError, "sprite_tiles :#{name} is declared on a bitmap screen. A bitmap screen paints its " \
                             "sprites into the picture and has no sprite memory to hold the tiles. To fix this, " \
                             "use `screen :tiled`."
      end

      def refuse_bad_tile_pose_pieces!(name, set_name, count, pieces)
        unless pieces.is_a?(Array) && !pieces.empty?
          raise ArgumentError, "image :#{name} gets its tiles from :#{set_name}, and needs pieces:, a list of " \
                               "[dx, dy, tile], like pieces: [[0, 0, 0], [8, 0, 1]]."
        end
        pieces.each do |piece|
          dx, dy, tile = piece
          unless piece.is_a?(Array) && piece.length == 3 && [dx, dy].all? { |side| side.is_a?(Integer) && side >= 0 && (side % 8).zero? }
            raise ArgumentError, "image :#{name} has the piece #{piece.inspect}. A piece is [dx, dy, tile], and dx " \
                                 "and dy are 0 or more and a multiple of 8, since each tile sits on the picture's " \
                                 "8-pixel grid."
          end
          next if tile.is_a?(Integer) && tile.between?(0, count - 1)

          raise ArgumentError, "image :#{name} has the piece #{piece.inspect}, and sprite_tiles :#{set_name} holds " \
                               "tiles 0 to #{count - 1}. To fix this, give a tile from 0 to #{count - 1}."
        end
        places = pieces.map { |dx, dy, _| [dx, dy] }
        return if places.uniq.length == places.length

        raise ArgumentError, "image :#{name} puts two pieces at the same place. To fix this, give each piece a " \
                             "place of its own."
      end
    end
  end
end
