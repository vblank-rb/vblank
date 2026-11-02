# frozen_string_literal: true

module VBlank
  module DSL
    # A GROUP OF TILES TAKING TURNS THROUGH PICTURES HELD IN THE CARTRIDGE, handed back by
    # `tile_pictures`. A map or a tileset names one of its tiles by `group[:key]`, and `show` says
    # which picture the whole group shows.
    class TilePictureGroup
      attr_reader :name

      def initialize(builder, name:, keys:, pictures:, list:, held:, run:, shown:)
        @builder = builder
        @name = name
        @keys = keys
        @pictures = pictures
        @list = list
        @held = held
        @run = run
        @shown = shown
      end

      # The name of the tile +key+, as a tileset takes a picture's name.
      def [](key)
        at = @keys.index(key)
        unless at
          raise ArgumentError, "tile_pictures :#{@name} has no tile #{key.inspect}. Its tiles are " \
                               "#{@keys.map(&:inspect).join(', ')}."
        end

        Messages::MadeNames.make(:tile_run_tile, run: @name, number: at + 1)
      end

      # The picture numbered +which+, counting from 0, shows on the next frame, on every tile of
      # the group. A number naming no picture leaves them as they are, and so does the number
      # showing already, for one compare.
      def show(which)
        wanted = Value.node_for(which)
        real = Build.binop(:and, Build.binop(:>=, wanted, Build.int(0)), Build.binop(:<, wanted, Build.int(@pictures)))
        @builder.with_test(Build.binop(:and, real, Build.binop(:!=, wanted, @shown.node))) do
          @builder.set_shown_tile_picture(@shown, wanted)
          copy_picture(wanted)
          @run.changed
        end
        nil
      end

      private

      def copy_picture(which)
        bytes = @keys.length * Builder::TileRuns::TILE_BYTES
        @list.copy_from(@held, at: Build.binop(:*, which, Build.int(bytes)), count: bytes)
      end

      Build = IR::Build
      private_constant :Build
    end
  end
end
