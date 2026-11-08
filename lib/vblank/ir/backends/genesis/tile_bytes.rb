# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A GENESIS TILE'S BYTES, from its pixels. Each of the 64 pixels is a place in a list of
        # sixteen colours (0 to 15), row by row. The Genesis keeps a pixel in four bits, two to a
        # byte, the left pixel in the top four: 32 bytes, four a row.
        module TileBytes
          # The 32 bytes of +places+, as a binary String.
          def self.of(places)
            places.each_slice(2).map { |left, right| (left << 4) | right }.pack("C*")
          end
        end
      end
    end
  end
end
