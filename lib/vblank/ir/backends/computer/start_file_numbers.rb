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
          # Eight is a tile of 256 colours, a byte a pixel (Console::BYTE_A_PIXEL_TILES).
          MOST_PLANES = 8

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
          # colours counts, whether the places are one byte each, the see-through place, and the
          # bytes from one row of a picture of bytes to the next.
          RULES_HEADER_NUMBERS = 14

          # The numbers before the tile layout in a background's rules
          # (StartFileFills#start_file_background_rules): the totals, where its map is and how its
          # cells are kept, where its tiles and its banks of colours are, how many sets of colours
          # its tiles are written in, how many tiles the game holds before the map's in each, how
          # many bytes a cell of its map is, and where the cells it is told by a slot are in the
          # file, how many, and which of the tiles the game holds is the first of theirs.
          BACKGROUND_HEADER_NUMBERS = 24

          # The numbers before the tile layout in a pose's rules (StartFileFills#start_file_pose_rules):
          # what is filled, the totals, how many copies of it there are, the turn, the colours, where
          # the frame's entry is in the file and where the frames' records start, the origin, where
          # the tiles are, and the bank a piece must name to be painted (-1 for every piece). How the
          # original keeps a frame is not among them: the file holds a record of VBlank's own for
          # each (Original::FrameRecord), which each runtime reads by that record's fixed layout.
          POSE_HEADER_NUMBERS = 15

          # The numbers before the colour layout in the rules of colours of a list the file chooses
          # (StartFileFills#chosen_color_rules): where the frame's entry is and where the frames'
          # records start, where the lists' colours are, how many colours a list is, how many
          # lists there are, and the first place filled.
          CHOSEN_COLORS_HEADER_NUMBERS = 6

          # THE LAYOUT OF A FRAME'S RECORD, as each runtime reads it: how many bytes a directory
          # entry, a frame's header and a piece are, and where each part of a piece is. They are
          # Original::FrameRecord's own numbers, the one place the layout is written down, handed on
          # under the names the runtimes know them by. That module loads after this one, so they are
          # asked for as a build is written and not as this file loads.
          def self.frame_record_names
            record = Original::FrameRecord
            { "RG_FRAME_ENTRY_BYTES" => record::ENTRY_BYTES, "RG_FRAME_HEADER_BYTES" => record::HEADER_BYTES,
              "RG_FRAME_PIECE_BYTES" => record::PIECE_BYTES, "RG_PIECE_X_AT" => record::X_AT, "RG_PIECE_Y_AT" => record::Y_AT,
              "RG_PIECE_TILE_AT" => record::TILE_AT, "RG_PIECE_COLUMN_STEP_AT" => record::COLUMN_STEP_AT,
              "RG_PIECE_ROW_STEP_AT" => record::ROW_STEP_AT, "RG_PIECE_COLUMNS_AT" => record::COLUMNS_AT,
              "RG_PIECE_ROWS_AT" => record::ROWS_AT, "RG_PIECE_TURNS_AT" => record::TURNS_AT,
              "RG_PIECE_BANK_AT" => record::BANK_AT,
              "RG_PIECE_MIRRORED" => record::MIRRORED, "RG_PIECE_UPSIDE_DOWN" => record::UPSIDE_DOWN }
          end

          # Every number written ahead of a runtime: NAMES, and the layout of a frame's record.
          def self.names = NAMES.merge(frame_record_names)

          NAMES = Ractor.make_shareable({
            "RG_FILL_POSE_HEADER_NUMBERS" => POSE_HEADER_NUMBERS,
            "RG_CHOSEN_COLORS_HEADER_NUMBERS" => CHOSEN_COLORS_HEADER_NUMBERS,
            "RG_TILE_BYTES_AT" => TILE_BYTES_AT, "RG_TILE_PLANES_AT" => TILE_PLANES_AT,
            "RG_TILE_PLANE_BITS_AT" => TILE_PLANE_BITS_AT, "RG_TILE_ROW_BITS_AT" => TILE_ROW_BITS_AT,
            "RG_TILE_COLUMN_BITS_AT" => TILE_COLUMN_BITS_AT, "RG_TILE_FORMAT_NUMBERS" => TILE_FORMAT_NUMBERS,
            "RG_COLOR_HIGH_BYTE_FIRST_AT" => COLOR_HIGH_BYTE_FIRST_AT, "RG_COLOR_RED_AT" => COLOR_RED_AT,
            "RG_COLOR_GREEN_AT" => COLOR_GREEN_AT, "RG_COLOR_BLUE_AT" => COLOR_BLUE_AT,
            "RG_COLOR_CHANNEL_BITS_AT" => COLOR_CHANNEL_BITS_AT, "RG_COLOR_FORMAT_NUMBERS" => COLOR_FORMAT_NUMBERS,
            "RG_FILL_RULES_HEADER_NUMBERS" => RULES_HEADER_NUMBERS,
            "RG_FILL_BACKGROUND_HEADER_NUMBERS" => BACKGROUND_HEADER_NUMBERS,
            # A number above this, of sixteen bits and not all of them, is a marker (IR::StartFile, "MARKERS").
            "RG_MARKED_COLOR" => IR::StartFile::MARKER
          })
        end
      end
    end
  end
end
