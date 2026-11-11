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

          # The numbers before the frame's layout in a pose's rules (StartFileFills#start_file_pose_rules):
          # what is filled, the totals, the turn, the colours, where the frame is and where its slot
          # ends, its count, the origin, and where the tiles are.
          POSE_HEADER_NUMBERS = 16

          # Where each number of a frame's layout (Original::FrameLayout) is, counted from where the
          # layout starts. A part the layout does not have is -1, but for the tile's bits, which
          # are 0 where the whole number is the tile.
          FRAME_PIECE_BYTES_AT = 0
          FRAME_COUNT_BYTES_AT = 1
          FRAME_HIGH_BYTE_FIRST_AT = 2
          FRAME_X_AT = 3
          FRAME_Y_AT = 4
          FRAME_POSITION_BYTES_AT = 5
          FRAME_TILE_AT = 6
          FRAME_TILE_BYTES_AT = 7
          FRAME_TILE_BITS_AT = 8
          FRAME_TILE_ROW_AT = 9
          FRAME_ROW_TILES_AT = 10
          FRAME_FLAGS_AT = 11
          FRAME_FLAGS_BYTES_AT = 12
          FRAME_MIRRORED_BIT_AT = 13
          FRAME_UPSIDE_DOWN_BIT_AT = 14
          FRAME_BIG_BIT_AT = 15
          FRAME_SIZE_AT = 16
          FRAME_COLUMNS_BIT_AT = 17
          FRAME_ROWS_BIT_AT = 18
          FRAME_SIZE_BITS_AT = 19
          FRAME_TILE_ORDER_AT = 20
          FRAME_LAYOUT_NUMBERS = 21

          # How a piece's tiles follow its first (Original::FrameLayout#tile_order): along rows of
          # video memory where the layout names no order, down columns, or across rows.
          FRAME_TILE_ORDERS = Ractor.make_shareable({ nil => 0, down_columns: 1, across_rows: 2 })

          NAMES = Ractor.make_shareable({
            "RG_FILL_POSE_HEADER_NUMBERS" => POSE_HEADER_NUMBERS,
            "RG_FRAME_PIECE_BYTES_AT" => FRAME_PIECE_BYTES_AT, "RG_FRAME_COUNT_BYTES_AT" => FRAME_COUNT_BYTES_AT,
            "RG_FRAME_HIGH_BYTE_FIRST_AT" => FRAME_HIGH_BYTE_FIRST_AT, "RG_FRAME_X_AT" => FRAME_X_AT, "RG_FRAME_Y_AT" => FRAME_Y_AT,
            "RG_FRAME_POSITION_BYTES_AT" => FRAME_POSITION_BYTES_AT, "RG_FRAME_TILE_AT" => FRAME_TILE_AT,
            "RG_FRAME_TILE_BYTES_AT" => FRAME_TILE_BYTES_AT, "RG_FRAME_TILE_BITS_AT" => FRAME_TILE_BITS_AT,
            "RG_FRAME_TILE_ROW_AT" => FRAME_TILE_ROW_AT, "RG_FRAME_ROW_TILES_AT" => FRAME_ROW_TILES_AT,
            "RG_FRAME_FLAGS_AT" => FRAME_FLAGS_AT, "RG_FRAME_FLAGS_BYTES_AT" => FRAME_FLAGS_BYTES_AT,
            "RG_FRAME_MIRRORED_BIT_AT" => FRAME_MIRRORED_BIT_AT, "RG_FRAME_UPSIDE_DOWN_BIT_AT" => FRAME_UPSIDE_DOWN_BIT_AT,
            "RG_FRAME_BIG_BIT_AT" => FRAME_BIG_BIT_AT, "RG_FRAME_SIZE_AT" => FRAME_SIZE_AT,
            "RG_FRAME_COLUMNS_BIT_AT" => FRAME_COLUMNS_BIT_AT, "RG_FRAME_ROWS_BIT_AT" => FRAME_ROWS_BIT_AT,
            "RG_FRAME_SIZE_BITS_AT" => FRAME_SIZE_BITS_AT, "RG_FRAME_TILE_ORDER_AT" => FRAME_TILE_ORDER_AT,
            "RG_FRAME_LAYOUT_NUMBERS" => FRAME_LAYOUT_NUMBERS,
            "RG_FRAME_TILES_DOWN_COLUMNS" => FRAME_TILE_ORDERS.fetch(:down_columns),
            "RG_FRAME_TILES_ACROSS_ROWS" => FRAME_TILE_ORDERS.fetch(:across_rows),
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
