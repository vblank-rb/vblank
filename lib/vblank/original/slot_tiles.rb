# frozen_string_literal: true

module VBlank
  module Original
    # THE TILES OF ONE SLOT OF TILES (a Slot of shape :tiles), each read from the slot's bytes the
    # first time a verb asks for it and kept after that. A build asks for a tile by its number, as
    # an Array is asked: #fetch, #first, #length.
    #
    # WHY ONE TILE AT A TIME, AND NOT THE WHOLE SLOT ONCE. An original keeps each sprite's tiles in
    # one sheet, and a sheet can be many thousands of tiles (the Minish Cap's are up to 18,163),
    # while one pose reads a handful of them. Reading a tile is 64 places worked out in Ruby, so
    # reading a whole sheet costs far more than every pose of a room together, and a whole game
    # reads many sheets. Read one tile at a time, a build costs what its poses and backgrounds
    # draw, however big the sheets they draw from. Kept once read, a tile two poses share is read
    # once.
    #
    # #from is the same tiles counted from a later tile on, as a handle `pack[:sheet].tile(n)`
    # counts them. It shares the tiles read so far, so every pose over one sheet fills one store.
    #
    # One belongs to one build (Builder::DataPacks#pack_slot_tiles), so the store it fills is never
    # shared between Ractors. Each tile handed out is frozen: two verbs reading one tile read the
    # same list, and neither can change it under the other.
    class SlotTiles
      # The tiles of +layout+ (a Slot of tiles) held in +bytes+, its bytes in the pack.
      def initialize(layout, bytes)
        @bytes = bytes
        @format = layout.format
        @count = IR::FormatReading.tile_count(bytes, @format)
        @first = 0
        @read = {}
      end

      # The same tiles from tile +first+ on: its tile 0 is this one's tile +first+.
      def from(first)
        view = dup
        view.start_at(@first + first)
        view
      end

      # How many tiles there are from the first on.
      def length = [@count - @first, 0].max

      # Tile +at+ (0 first; below 0 counts back from the end) as its 64 places row by row, or what
      # the block gives where there is no such tile, as Array#fetch does.
      def fetch(at)
        index = at.negative? ? at + length : at
        return yield(at) unless index.between?(0, length - 1)

        whole = @first + index
        @read[whole] ||= IR::FormatReading.tile(@bytes, @format, whole).freeze
      end

      # The first tile, or nil where there is none.
      def first = fetch(0) { nil }

      # Up to +count+ tiles from tile +start+ on, as Array#slice takes them.
      def slice(start, count) = (start...[start + count, length].min).map { |at| fetch(at) }

      # How many different tiles have been read from the slot's bytes so far, by this and every
      # view #from made. Asked by the test that holds a build's cost to the tiles it draws
      # (Builder::DataPacks#pack_tiles_read).
      def tiles_read = @read.length

      protected

      def start_at(first)
        @first = first
      end
    end
  end
end
