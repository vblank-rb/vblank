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

          ROW_BYTES = 4
          ROWS = 8
          BYTES = ROW_BYTES * ROWS

          # The tile +bytes+ read right to left: each row's bytes in the other order, and the two
          # pixels of each byte changed over.
          def self.mirrored(bytes)
            bytes.unpack("C*").each_slice(ROW_BYTES).flat_map { |row| row.reverse.map { |both| ((both & 0x0F) << 4) | (both >> 4) } }.pack("C*")
          end

          # The tile +bytes+ read bottom to top: its rows in the other order.
          def self.upside_down(bytes)
            (0...ROWS).map { |row| bytes.byteslice(row * ROW_BYTES, ROW_BYTES) }.reverse.join.b
          end
        end
      end
    end
  end
end
