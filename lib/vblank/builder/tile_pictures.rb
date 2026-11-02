# frozen_string_literal: true

module VBlank
  class Builder
    # TILES WITH SEVERAL PICTURES HELD IN THE CARTRIDGE: `tile_pictures :water, colors: :pond,
    # tiles: { deep: %i[deep0 deep1 deep2], edge: %i[edge0 edge1 edge2] }`.
    #
    # Flowers that sway and water that lapses are a handful of tiles taking turns through a short
    # loop of pictures, over a map that does not change. Every picture is drawn ahead of time, so
    # the game has only to say which one a group shows, and the whole group changes as one.
    #
    # They stand on painted tiles (see TileRuns), which is what makes them work everywhere a
    # background does: a group is a run of tiles, never merged with any other, whose colours come
    # from one list, so a picture is the same place numbers as any drawn from that list.
    module TilePictures
      # The tiles in a group, and a group's picture bytes, are kept to what a game can use.
      TILE_BYTES = TileRuns::TILE_BYTES

      # The group +name+: each key of +tiles+ is one tile, and its value the pictures it goes
      # through, in order, the same number for each. +colors+ is the `colors` list they are all
      # drawn from. The tiles show their first pictures from the start.
      def tile_pictures(name, tiles:, colors:, fast: false)
        refuse_bad_tile_pictures!(name, tiles, colors)
        count = tiles.length
        pictures = tiles.each_value.first.length
        list_name = Messages::MadeNames.make(:tile_pictures_part, group: name, part: :shown)
        at_boot(Build.list_new(list_name, count * TILE_BYTES, width: :byte, fast: fast, full_of: 0))
        list = DSL::List.new(self, list_name)
        bytes = (0...pictures).flat_map { |picture| tiles.values.flat_map { |row| tile_picture_bytes(name, row[picture], colors) } }
        held = table(Messages::MadeNames.make(:tile_pictures_part, group: name, part: :pictures), bytes, width: :byte, signed: false)
        run = self.tiles(name, { from: list, count: count, colors: colors, held_in: held.name })
        # At power-on, not here: this line can be inside a scene, whose body runs every pass, and
        # the first picture would be put back every time. A scene's screen copies a run in as it
        # comes up, so only a group declared outside any scene has its first copy to ask for.
        at_boot(Build.list_copy(list_name, table: held.name, at: Build.int(0), count: count * TILE_BYTES))
        run.changed(now: true) unless recording_game_code?
        shown = var(Messages::MadeNames.make(:tile_pictures_part, group: name, part: :picture), 0)
        DSL::TilePictureGroup.new(self, name: name, keys: tiles.keys, pictures: pictures, list: list, held: held, run: run,
                                        shown: shown)
      end

      # The block's statements, run where +test+ holds, for a group's `show`.
      def with_test(test, &block) = push_container(Build.if_(test), &block)

      # Keep which picture a group shows.
      def set_shown_tile_picture(shown, wanted) = record(Build.set(shown.name, wanted))

      private

      # The 32 bytes of a tile's picture as painted tiles keep them: two places a byte, the left
      # one in the low four bits.
      def tile_picture_bytes(name, image, colors)
        node = @program.walk.find { |each| each.kind == :bitmap && each.name == image }
        unless node
          raise ArgumentError, "tile_pictures :#{name} names the picture :#{image}, and no image has that name. Declare it " \
                               "first with `image :#{image}, ...`."
        end

        picture = IR::Assets::Image.of(node)
        unless [picture.width, picture.height] == [8, 8]
          raise ArgumentError, "tile_pictures :#{name} names the picture :#{image}, which is #{picture.width}x#{picture.height}. " \
                               "Each picture is one tile, so it must be 8x8."
        end
        unless picture.colors_name == colors
          raise ArgumentError, "tile_pictures :#{name} is drawn from colors :#{colors}, and the picture :#{image} is not. " \
                               "To fix this, draw it with `image :#{image}, colors: :#{colors}, ...`."
        end

        places = picture.places.bytes
        places.each_slice(2).map { |left, right| left | (right << 4) }
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
