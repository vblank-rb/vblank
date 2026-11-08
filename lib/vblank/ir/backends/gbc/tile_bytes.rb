# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # A COLOR TILE'S BYTES, from its pixels. Each pixel is a place in a list of four colours
        # (0 to 3), eight to a row. The Color keeps a row in two bytes: the low bit of each place in
        # the first and the high bit in the second, the leftmost pixel in bit 7. Sixty-four places
        # are one tile; a tall sprite piece's 128 are its upper tile and then its lower.
        module TileBytes
          # The bytes of +places+, as numbers 0 to 255, two a row.
          def self.of(places)
            (0...(places.length / 8)).flat_map do |row|
              line = places[row * 8, 8]
              low = line.each_with_index.sum { |place, x| (place & 1) << (7 - x) }
              high = line.each_with_index.sum { |place, x| ((place >> 1) & 1) << (7 - x) }
              [low, high]
            end
          end
        end
      end
    end
  end
end
