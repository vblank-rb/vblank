# frozen_string_literal: true

module VBlank
  module DSL
    # Sprite tiles the game rewrites
    #
    # A set of sprite tiles, made with `sprite_tiles`, is a few tiles of sprite memory that
    # poses are drawn from and that the game fills with other pixels as it runs. A pose drawn
    # from it is a picture like any other (`image :spin0, tiles_from: :ball_tiles, pieces: [...]`),
    # and loading new tiles into the set changes every pose that draws them.
    #
    # ```ruby
    # ball_tiles = sprite_tiles :ball_tiles, count: 32, colors: :ball
    # image :spin0, tiles_from: :ball_tiles, pieces: [[0, 0, 0], [8, 0, 1], [0, 8, 2], [8, 8, 3]]
    # ball_tiles.copy_from :great_ball, at: 0, count: 4, to: 0
    # ```
    class SpriteTileSet
      # The name the set was given.
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # Loads tiles into the set from a picture or a table, and returns the set.
      #
      # The set's tiles from `to` on take `count` tiles of `source`, from its tile `at` on. Every
      # pose drawing one of those tiles shows the new pixels in the picture of the pass that
      # loaded them. A load that would reach past the end of the set or of the source changes
      # nothing. A pass can load at most eight times, since the console copies a pass's loads in
      # the short gap after it.
      #
      # ```ruby
      # ball_tiles.copy_from :great_ball, at: kind * 4, count: 4, to: 0
      # ```
      #
      # * `source` - an image drawn from the set's colours, whose tiles are counted left to right
      #   and then top to bottom, or a `table` of bytes holding tiles as painted tiles keep them.
      # * `at:` - the first tile of the source to copy. The game can work it out as it runs.
      # * `count:` - how many tiles to copy: a number written in the game.
      # * `to:` - the first tile of the set to copy into. The game can work it out as it runs.
      def copy_from(source, at:, count:, to:)
        @builder.load_sprite_tiles(@name, source, at: at, count: count, to: to)
        self
      end
    end
  end
end
