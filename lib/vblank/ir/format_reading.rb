# frozen_string_literal: true

module VBlank
  module IR
    # READING AN ORIGINAL'S TILES, COLOURS AND NUMBERS in the layout a console keeps them in
    # (Console::TileFormat, ColorFormat, NumberFormat): a slot of a data pack as the game is built
    # (Original::Slot#decode), and a file the program is handed as it starts on the interpreter
    # (StartFile.filled). The runtimes for a computer read them the same way from the same numbers
    # (start_file_place, start_file_color and start_file_channel in rg_runtime.c, each written again
    # in the JavaScript and Ruby runtimes with rg_ before it), and each function here says which of
    # theirs it is.
    module FormatReading
      TILE_SIDE = 8
      TILE_PIXELS = TILE_SIDE * TILE_SIDE

      module_function

      # Tiles kept one after another in +bytes+, each read as its 64 places row by row.
      def tiles(bytes, format)
        (0...(bytes.bytesize / format.tile_bytes)).map do |tile|
          (0...TILE_PIXELS).map { |at| place(bytes, format, tile * format.tile_bytes, at % TILE_SIDE, at / TILE_SIDE) }
        end
      end

      # The place of the pixel at column +x+ and row +y+ of the tile whose bytes start at +start+
      # (start_file_place).
      def place(bytes, format, start, x, y)
        format.plane_bits.each_with_index.sum do |plane_at, plane|
          bit = plane_at + (y * format.row_bits) + format.column_bits[x]
          ((bytes.getbyte(start + (bit / 8)) >> (bit % 8)) & 1) << plane
        end
      end

      # Colours kept two bytes each in +bytes+, each as its fifteen bits (start_file_color).
      def colors(bytes, format)
        bytes.unpack(format.high_byte_first ? "n*" : "v*").map do |kept|
          channel(kept, format.red_at, format) | (channel(kept, format.green_at, format) << 5) |
            (channel(kept, format.blue_at, format) << 10)
        end
      end

      # The channel at bit +at+ of a colour kept as +kept+, widened to five bits by repeating its
      # top bits, so the brightest of any width is 31 (start_file_channel).
      def channel(kept, at, format)
        bits = format.channel_bits
        level = (kept >> at) & ((1 << bits) - 1)
        bits >= 5 ? level : (level << (5 - bits)) | (level >> ((2 * bits) - 5))
      end

      # Numbers +width+ wide kept in +bytes+, below zero only when +signed+ (Build.elements_of).
      def numbers(bytes, format, width:, signed:)
        Build.elements_of(bytes, width: width, signed: signed, high_byte_first: format.high_byte_first)
      end
    end
  end
end
