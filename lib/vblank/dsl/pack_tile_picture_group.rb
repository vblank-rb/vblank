# frozen_string_literal: true

module VBlank
  module DSL
    # A data pack's tiles taking turns through pictures
    #
    # `tile_pictures`, given tiles of a data pack slot, hands one back: a group of the pack's
    # tiles that take turns through pictures of the pack. The backgrounds drawn from the tiles'
    # slot show them wherever their maps name them, so a group has no tile names to hand out;
    # #show sets which picture every one of its tiles shows.
    #
    # ```ruby
    # belt = tile_pictures :belt, tiles: { pack[:video].tile(0xF3) => pack[:belt].tiles(0, across: 16) }
    # background :lair, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 64
    #
    # game_loop do
    #   passes += 1
    #   belt.show((passes / 4) % 16)    # the conveyor's pegs crawl
    # end
    # ```
    #--
    # Made by Builder::PackTilePictures.
    #++
    class PackTilePictureGroup
      # The name the group was declared with.
      attr_reader :name

      def initialize(builder, name:, pictures:, shown:, routine:)
        @builder = builder
        @name = name
        @pictures = pictures
        @shown = shown
        @routine = routine
      end

      # Shows the picture numbered `which`, counting from 0, on every cell naming one of the
      # group's tiles, from the next frame on.
      #
      # `which` may be a number the game works out. A number naming no picture leaves the cells as
      # they are, and so does the number showing already, for the cost of one comparison.
      def show(which)
        wanted = Value.node_for(which)
        real = Build.binop(:and, Build.binop(:>=, wanted, Build.int(0)), Build.binop(:<, wanted, Build.int(@pictures)))
        @builder.with_test(Build.binop(:and, real, Build.binop(:!=, wanted, @shown.node))) do
          @builder.set_shown_tile_picture(@shown, wanted)
          @builder.call(@routine)
        end
        nil
      end

      Build = IR::Build
      private_constant :Build
    end
  end
end
