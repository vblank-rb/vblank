# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # HOW MANY NUMBERS, AND WHERE, a picture read from the start file is handed to the runtimes
        # in (StartFileFills#start_file_fill_rules): the layout its tiles are kept in, then the
        # layout its colours are kept in. Written ahead of each runtime with the console's numbers
        # (ConsoleNumbers#values), so the C, JavaScript and Ruby runtimes read the same names and
        # the lowering that writes the rules is the only other place that knows the order.
        module StartFileNumbers
          # The most bit planes a tile has (Console::TileFormat#plane_bits); the unused ones are 0.
          MOST_PLANES = 4

          # Where each number of a tile's layout is, counted from where the layout starts.
          TILE_BYTES_AT = 0
          TILE_PLANES_AT = 1
          TILE_PLANE_BITS_AT = 2
          TILE_ROW_BITS_AT = TILE_PLANE_BITS_AT + MOST_PLANES
          TILE_COLUMN_BITS_AT = TILE_ROW_BITS_AT + 1
          TILE_FORMAT_NUMBERS = TILE_COLUMN_BITS_AT + IR::FormatReading::TILE_SIDE

          # Where each number of a colour's layout is.
          COLOR_HIGH_BYTE_FIRST_AT = 0
          COLOR_RED_AT = 1
          COLOR_GREEN_AT = 2
          COLOR_BLUE_AT = 3
          COLOR_CHANNEL_BITS_AT = 4
          COLOR_FORMAT_NUMBERS = 5

          # The numbers before the tile layout: what is filled, the totals, the turn, the places and
          # colours counts, whether the places are one byte each, and the see-through place.
          RULES_HEADER_NUMBERS = 13

          # The numbers before the tile layout in a background's rules
          # (StartFileFills#start_file_background_rules): the totals, where its map is and how its
          # cells are kept, and where its tiles and its banks of colours are.
          BACKGROUND_HEADER_NUMBERS = 19

          NAMES = Ractor.make_shareable({
            "RG_TILE_BYTES_AT" => TILE_BYTES_AT, "RG_TILE_PLANES_AT" => TILE_PLANES_AT,
            "RG_TILE_PLANE_BITS_AT" => TILE_PLANE_BITS_AT, "RG_TILE_ROW_BITS_AT" => TILE_ROW_BITS_AT,
            "RG_TILE_COLUMN_BITS_AT" => TILE_COLUMN_BITS_AT, "RG_TILE_FORMAT_NUMBERS" => TILE_FORMAT_NUMBERS,
            "RG_COLOR_HIGH_BYTE_FIRST_AT" => COLOR_HIGH_BYTE_FIRST_AT, "RG_COLOR_RED_AT" => COLOR_RED_AT,
            "RG_COLOR_GREEN_AT" => COLOR_GREEN_AT, "RG_COLOR_BLUE_AT" => COLOR_BLUE_AT,
            "RG_COLOR_CHANNEL_BITS_AT" => COLOR_CHANNEL_BITS_AT, "RG_COLOR_FORMAT_NUMBERS" => COLOR_FORMAT_NUMBERS,
            "RG_FILL_RULES_HEADER_NUMBERS" => RULES_HEADER_NUMBERS,
            "RG_FILL_BACKGROUND_HEADER_NUMBERS" => BACKGROUND_HEADER_NUMBERS
          })
        end
      end
    end
  end
end
