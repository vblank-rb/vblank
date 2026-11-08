# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A SUPER NINTENDO TILE'S BYTES, from its pixels. Each of the 64 pixels is a place in a list
        # of sixteen colours (0 to 15), row by row. The console keeps the four bits of a place in
        # four planes: each row's bits 0 and 1 as two bytes, all eight rows, then bits 2 and 3 the
        # same way. The leftmost pixel is the top bit of each byte: 32 bytes.
        module TileBytes
          # The 32 bytes of +places+, as a binary String.
          def self.of(places)
            low = +"".b
            high = +"".b
            8.times do |row|
              planes = Array.new(4) do |plane|
                (0...8).sum { |column| ((places[(row * 8) + column] >> plane) & 1) << (7 - column) }
              end
              low << planes[0].chr << planes[1].chr
              high << planes[2].chr << planes[3].chr
            end
            low + high
          end
        end
      end
    end
  end
end
