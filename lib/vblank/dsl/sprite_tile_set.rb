# frozen_string_literal: true

module VBlank
  module DSL
    # A SET OF SPRITE TILES THE GAME LOADS AS IT RUNS, handed back by `sprite_tiles`. Poses drawn
    # from it are pictures (`image :spin0, tiles_from: :ball_tiles, pieces: [...]`); this is how
    # the game puts other pixels in its tiles.
    class SpriteTileSet
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # Tiles +to+ onwards of the set take +count+ tiles of +source+, from its tile +at+ on. The
      # source is an image drawn from the set's colours, whose tiles are counted left to right
      # and then top to bottom, or a table of bytes holding tiles as painted tiles keep them.
      # +at+ and +to+ may be worked out as the game runs; +count+ is a number written in the
      # program. Every pose drawing one of those tiles shows the new pixels from the next frame,
      # and a load that would reach past the end of the set or of the source changes nothing.
      def copy_from(source, at:, count:, to:)
        @builder.load_sprite_tiles(@name, source, at: at, count: count, to: to)
        self
      end
    end
  end
end
