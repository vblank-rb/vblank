# frozen_string_literal: true

module VBlank
  class Builder
    # Tiles that take turns through pictures
    #
    # Flowers that sway and water that laps are a handful of tiles taking turns through a short
    # loop of pictures, over a map that does not change. Every picture is drawn ahead of time, so
    # the game only names which one a group shows, and the whole group changes as one.
    #
    # ```ruby picture=loop frames=48
    # # Three pictures of one tile: water (1)
    # # with a crest (2) that moves along.
    # WAVES = (0..2).map do |n|
    #   Array.new(64) do |at|
    #     row, col = at.divmod(8)
    #     row.even? && col / 3 == n ? 2 : 1
    #   end
    # end
    #
    # VBlank.game "WATER", consoles: %i[gba] do
    #   screen :tiled, backdrop: rgb(3, 4, 7)
    #   colors :pond, [:transparent,
    #                  rgb(6, 10, 22), :cyan]
    #   WAVES.each_with_index do |places, n|
    #     image :"wave#{n}", width: 8, height: 8,
    #           colors: :pond, places: places
    #   end
    #   water = tile_pictures :water,
    #     colors: :pond,
    #     tiles: { wave: %i[wave0 wave1 wave2] }
    #   tiles :lake_tiles, "~" => water[:wave]
    #   background :lake, tiles: :lake_tiles,
    #                     map: "#{'~' * 8}\n" * 4
    #   step = 0
    #   game_loop do
    #     step += 1
    #     # every tile of the lake changes at once
    #     water.show (step / 8) % 3
    #   end
    # end
    # ```
    #
    # ```ruby
    # tile_pictures :water, colors: :pond,
    #                       tiles: { deep: %i[deep0 deep1 deep2], edge: %i[edge0 edge1 edge2] }
    # ```
    #--
    # They stand on painted tiles (see TileRuns), which is what makes them work everywhere a
    # background does: a group is a run of tiles, never merged with any other, whose colours come
    # from one list, so a picture is the same place numbers as any drawn from that list.
    #++
    module TilePictures
      # The tiles in a group, and a group's picture bytes, are kept to what a game can use.
      TILE_BYTES = TileRuns::TILE_BYTES  # :nodoc:

      # One run of a group (#declare_tile_picture_run).
      TilePictureRun = Data.define(:list, :held, :run, :bytes_shown)  # :nodoc:

      # Declares a group of tiles that take turns through pictures, and returns the group.
      #
      # Each key of `tiles` is one tile, and its value is the pictures the tile goes through, in
      # order, with the same number for each tile. The tiles show their first pictures from the
      # start. Name which picture the group shows with the group the verb returns.
      #
      # A key can also be a tile of a data pack slot, such as `pack[:video].tile(5)`. It is then a
      # tile of the backgrounds drawn from that slot, its pictures are tiles of the pack too, and
      # the colours are the bank each cell names, so there is no `colors:`.
      #
      # ```ruby
      # field = tile_pictures :field, colors: :meadow, tiles: { flower: %i[upright left upright right] }
      # tiles :meadow_tiles, "f" => field[:flower], "." => :grass
      #
      # game_loop do
      #   passes += 1
      #   field.show((passes / 15) % 4)   # a new picture every quarter second
      # end
      # ```
      #
      # * `name` - the group's name, as a symbol.
      # * `tiles:` - a hash from each tile's key to the list of its pictures.
      # * `colors:` - the `colors` list every picture is drawn from.
      # * `fast:` - `true` to keep the pictures in the quick memory.
      #--
      # PackTilePictures handles the data pack form.
      #++
      def tile_pictures(name, tiles:, colors: nil, fast: false)
        return declare_pack_tile_pictures(name, tiles, colors, fast: fast) if pack_tile_pictures?(tiles)

        refuse_bad_tile_pictures!(name, tiles, colors)
        side = tile_picture_side(name, tiles)
        pictures = tiles.each_value.first.length
        bytes = (0...pictures).flat_map { |picture| tiles.values.flat_map { |row| tile_picture_bytes(name, row[picture], colors, side) } }
        part = declare_tile_picture_run(name, count: tiles.length, colors: colors, side: side, bytes: bytes, fast: fast)
        shown = var(Messages::MadeNames.make(:tile_pictures_part, group: name, part: :picture), 0)
        DSL::TilePictureGroup.new(self, name: name, keys: tiles.keys, pictures: pictures, list: part.list, held: part.held,
                                        run: part.run, shown: shown, bytes_shown: part.bytes_shown)
      end

      # One run of tiles taking turns through pictures: the run +name+ of +count+ tiles +side+
      # pixels square drawn from +colors+, the list in memory it shows, and the table in the
      # cartridge holding +bytes+, each picture's tiles one after another. A group of `tile_pictures`
      # is one of these; a group of a pack's tiles is one for each background and bank that draws
      # it. +held+ is a table the caller made (a DSL::Table) in place of one made of +bytes+.
      # +shown_in+ is a list the caller made and fills (PackTilePictures#pictures_shown_at_start), for
      # runs that all show the same bytes, in place of a list of the run's own.
      # Hands back a TilePictureRun: the list, the table (a DSL::Table), the run, and the bytes a
      # picture takes.
      private def declare_tile_picture_run(name, count:, colors:, side:, bytes:, fast:, held: nil, shown_in: nil)
        bytes_shown = count * TILE_BYTES * ((side / 8)**2)
        list_name = shown_in&.name || Messages::MadeNames.make(:tile_pictures_part, group: name, part: :shown)
        at_boot(Build.list_new(list_name, bytes_shown, width: :byte, fast: fast, full_of: 0)) unless shown_in
        list = shown_in || DSL::List.new(self, list_name)
        held ||= table(Messages::MadeNames.make(:tile_pictures_part, group: name, part: :pictures), bytes, width: :byte, signed: false)
        run = self.tiles(name, { from: list, count: count, colors: colors, held_in: held.name, tile_side: side })
        # At power-on, not here: this line can be inside a scene, whose body runs every pass, and
        # the first picture would be put back every time. A scene's screen copies a run in as it
        # comes up, so only a group declared outside any scene has its first copy to ask for.
        at_boot(Build.list_copy(list_name, table: held.name, at: Build.int(0), count: bytes_shown)) unless shown_in
        run.changed(now: true) unless recording_game_code?
        TilePictureRun.new(list: list, held: held, run: run, bytes_shown: bytes_shown)
      end

      # The block's statements, run where +test+ holds, for a group's `show`.
      # Hook a tile-picture group's `show` calls; documented on `tiles`.
      def with_test(test, &block) = push_container(Build.if_(test), &block)  # :nodoc:

      # Keep which picture a group shows.
      # Hook a tile-picture group calls to keep which picture it shows; documented on `tiles`.
      def set_shown_tile_picture(shown, wanted) = record(Build.set(shown.name, wanted))  # :nodoc:

      private

      # The side of the tiles in a group: 8, or 16 where the console draws tiles that big. Every
      # picture in a group is one size, since a group's tiles stand in one tileset.
      def tile_picture_side(name, tiles)
        sizes = tiles.values.flatten.map { |image| tile_picture_node(name, image) }.map { |node| IR::Assets::Image.of(node) }
                     .map { |picture| [picture.width, picture.height] }.uniq
        unless sizes.one?
          raise ArgumentError, "tile_pictures :#{name} has pictures of different sizes: " \
                               "#{sizes.map { |width, height| "#{width}x#{height}" }.join(', ')}. Each picture is one " \
                               "tile, and the tiles in a tileset are all the same size."
        end
        return sizes.first.first if [[8, 8], [16, 16]].include?(sizes.first)

        raise ArgumentError, "tile_pictures :#{name} has pictures of #{sizes.first.join('x')}. Each picture is one tile, " \
                             "so it must be 8x8 or 16x16."
      end

      def tile_picture_node(name, image)
        @program.walk.find { |each| each.kind == :bitmap && each.name == image } ||
          raise(ArgumentError, "tile_pictures :#{name} names the picture :#{image}, and no image has that name. Declare it " \
                               "first with `image :#{image}, ...`.")
      end

      # A tile's picture as painted tiles keep it: 32 bytes for each 8×8 square of it, left to right
      # and then down, two places a byte, the left one in the low four bits. A console that keeps
      # its tiles another way turns them when its cartridge is built (GBC::Lowering::TileRuns).
      def tile_picture_bytes(name, image, colors, side)
        picture = IR::Assets::Image.of(tile_picture_node(name, image))
        unless picture.colors_name == colors
          raise ArgumentError, "tile_pictures :#{name} is drawn from colors :#{colors}, and the picture :#{image} is not. " \
                               "To fix this, draw it with `image :#{image}, colors: :#{colors}, ...`."
        end

        places = picture.places.bytes
        (0...side).step(8).to_a.product((0...side).step(8).to_a).flat_map do |top, left|
          (0...8).flat_map do |row|
            places[((top + row) * side) + left, 8].each_slice(2).map { |near, far| near | (far << 4) }
          end
        end
      end

      def refuse_bad_tile_pictures!(name, tiles, colors)
        unless colors.is_a?(Symbol)
          raise ArgumentError, "tile_pictures :#{name} needs `colors:`, the name of a `colors` list its pictures are drawn from."
        end
        unless tiles.is_a?(Hash) && !tiles.empty? && tiles.each_value.all? { |row| row.is_a?(Array) && !row.empty? }
          raise ArgumentError, "tile_pictures :#{name} needs `tiles:`, a Hash of each tile to the list of pictures it goes through."
        end
        return if tiles.each_value.map(&:length).uniq.one?

        raise ArgumentError, "tile_pictures :#{name} gives its tiles different numbers of pictures. One word picks the " \
                             "picture of the whole group, so each tile needs the same number. To fix this, make the lists " \
                             "the same length, or put the tiles in groups of their own."
      end
    end
  end
end
