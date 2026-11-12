# frozen_string_literal: true

module VBlank
  module DSL
    # A GROUP OF A DATA PACK'S TILES TAKING TURNS THROUGH PICTURES OF THE PACK, handed back by
    # `tile_pictures` given tiles of the pack (Builder::PackTilePictures). The backgrounds drawn
    # from the tiles' slot show them wherever their maps name them, so a group has no tile names
    # to hand out; `show` sets which picture every one of its tiles shows.
    class PackTilePictureGroup
      attr_reader :name

      def initialize(builder, name:, pictures:, shown:, routine:)
        @builder = builder
        @name = name
        @pictures = pictures
        @shown = shown
        @routine = routine
      end

      # The picture numbered +which+, counting from 0, shows on the next frame, on every cell
      # naming one of the group's tiles. A number naming no picture leaves them as they are, and so
      # does the number showing already, for one compare.
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
