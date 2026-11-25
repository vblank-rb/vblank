# frozen_string_literal: true

module VBlank
  module DSL
    # Tiles taking turns through pictures
    #
    # `tile_pictures` hands one back: a group of tiles that take turns through pictures held in
    # the cartridge. A map or a tileset names one of its tiles by `group[:key]`, and #show sets
    # which picture the whole group shows.
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
    class TilePictureGroup
      # The name the group was declared with.
      attr_reader :name

      def initialize(builder, name:, keys:, pictures:, list:, held:, run:, shown:, bytes_shown:)
        @builder = builder
        @bytes_shown = bytes_shown
        @name = name
        @keys = keys
        @pictures = pictures
        @list = list
        @held = held
        @run = run
        @shown = shown
      end

      # The name of the group's tile `key`, to put in a tileset as a picture's name is put.
      #
      # A key the group does not have is refused, naming the keys it has.
      def [](key)
        at = @keys.index(key)
        unless at
          raise ArgumentError, "tile_pictures :#{@name} has no tile #{key.inspect}. Its tiles are " \
                               "#{@keys.map(&:inspect).join(', ')}."
        end

        Messages::MadeNames.make(:tile_run_tile, run: @name, number: at + 1)
      end

      # Shows the picture numbered `which`, counting from 0, on every tile of the group, from the
      # next frame on.
      #
      # `which` may be a number the game works out. A number naming no picture leaves the tiles as
      # they are, and so does the number showing already, for the cost of one comparison.
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
        @list.copy_from(@held, at: Build.binop(:*, which, Build.int(@bytes_shown)), count: @bytes_shown)
      end

      Build = IR::Build
      private_constant :Build
    end
  end
end
