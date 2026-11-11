# frozen_string_literal: true

module VBlank
  module Original
    # ONE PIECE OF A FRAME, as its record says (FrameLayout#piece_of): where it sits from the
    # object's place, which tile it starts at, turned how, and how many tiles it is across and down.
    FramePiece = Data.define(:x, :y, :tile, :mirrored, :upside_down, :columns, :rows)

    # HOW AN ORIGINAL KEEPS ONE FRAME OF A SPRITE: a list of pieces, each a few bytes saying where
    # the piece sits, which tile it shows, and whether it is turned or big. A retail game copies a
    # frame's pieces into the console's sprite table each time a pose changes, adding the object's
    # place. The record is the game's own, so the port describes it here, by where each part is,
    # and a pose is read from it (`image ..., frame: pack[:frames].frame(at, layout: FRAME)`).
    #
    #   FRAME = VBlank::Original::FrameLayout.new(
    #     piece_bytes: 5, counted: true,
    #     x_at: 0, y_at: 1, tile_row_at: 2, tile_at: 3, row_tiles: 16,
    #     flags_at: 4, mirrored_bit: 6, upside_down_bit: 7, big_bit: 5
    #   )
    #
    # +piece_bytes+ is how many bytes a piece takes. +counted+ is true where the frame starts with
    # how many pieces follow; false where the game names the count (`frame(at, count:, ...)`).
    # Each +_at+ is a byte of a piece, counted from its first: x and y are signed, from the
    # object's place, and the tile is the byte at +tile_at+, plus +row_tiles+ times the byte at
    # +tile_row_at+ where the original names a row of sprite memory apart (nil where it does not).
    # The byte at +flags_at+ holds the bits: +mirrored_bit+ and +upside_down_bit+ (nil for an
    # original whose pieces never turn), and +big_bit+ for a piece of 16x16, which is the tiles t,
    # t + 1, t + row_tiles and t + row_tiles + 1 (nil for an original whose pieces are all 8x8).
    # Other bits are not read: a piece's bank of colours is the pose's `colors:` list, as a retail
    # game takes its sprite's colours from the object.
    #
    # A PART THAT IS TWO BYTES. Many originals keep a frame as the console's own sprite table
    # entries, with the object's place taken off, and those entries hold words:
    #
    #   FRAME = VBlank::Original::FrameLayout.new(
    #     piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    #     y_at: 0, x_at: 6, position_bytes: 2,
    #     tile_at: 4, tile_bytes: 2, tile_bits: 11,
    #     flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12,
    #     size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
    #   )
    #
    # +count_bytes+, +position_bytes+ (x and y), +tile_bytes+ and +flags_bytes+ are each 1 or 2,
    # and 1 where not given. A part of two bytes starts at its +_at+, and +high_byte_first+ says
    # which of the two comes first in the original: true or false, and it must be given, since
    # consoles differ and a wrong guess is a scrambled picture. +tile_bits+ is how many of the low
    # bits at +tile_at+ are the tile's number, for an original that keeps the tile and its turns in
    # one word: the flags are then read from the same place (+flags_at+ the same as +tile_at+), and
    # a +_bit+ may be up to 15.
    #
    # A PIECE OF SEVERAL TILES EACH WAY. The byte at +size_at+ holds two numbers of +size_bits+
    # bits each: how many tiles the piece is across, less one, from bit +columns_bit+ up, and how
    # many down, less one, from bit +rows_bit+ up. +tile_order+ says how the piece's tiles follow
    # its first in sprite memory, which is the console's choice and not the game's:
    # +:down_columns+ where t + 1 is BELOW t and the next column starts at t + rows, and
    # +:across_rows+ where t + 1 is right of t and the next row starts at t + columns. A piece
    # that is mirrored or upside down is turned whole, so its columns or rows change places too,
    # as the console turns a sprite.
    FrameLayout = Data.define(:piece_bytes, :counted, :x_at, :y_at, :tile_at, :tile_row_at, :row_tiles, :flags_at,
                              :mirrored_bit, :upside_down_bit, :big_bit, :high_byte_first, :count_bytes,
                              :position_bytes, :tile_bytes, :tile_bits, :flags_bytes, :size_at, :columns_bit,
                              :rows_bit, :size_bits, :tile_order) do
      def initialize(piece_bytes:, counted:, x_at:, y_at:, tile_at:, flags_at:, mirrored_bit: nil, upside_down_bit: nil,
                     tile_row_at: nil, row_tiles: 16, big_bit: nil, high_byte_first: nil, count_bytes: 1,
                     position_bytes: 1, tile_bytes: 1, tile_bits: nil, flags_bytes: 1, size_at: nil, columns_bit: nil,
                     rows_bit: nil, size_bits: 2, tile_order: nil)
        widths = [count_bytes, position_bytes, tile_bytes, flags_bytes]
        refuse_bad_widths!(widths, high_byte_first)
        refuse_bad_places!(piece_bytes, { x_at => position_bytes, y_at => position_bytes, tile_at => tile_bytes,
                                          flags_at => flags_bytes, tile_row_at => 1, size_at => 1 })
        refuse_bad_bits!(counted, [mirrored_bit, upside_down_bit, big_bit].compact, flags_bytes, row_tiles, tile_bits,
                         tile_bytes)
        refuse_bad_size!(size_at, [columns_bit, rows_bit], size_bits, tile_order, big_bit)
        super
      end

      # How many bytes of a frame come before its first piece: its count, where it has one.
      def count_bytes_before_pieces = counted ? count_bytes : 0

      # How many pieces a frame has, from the bytes it starts with (+count_bytes_before_pieces+ of them).
      def count_of(bytes) = number_at(bytes, 0, count_bytes, signed: false)

      # The piece +record+ (its +piece_bytes+ bytes, as Integers) holds (a FramePiece).
      def piece_of(record)
        flags = number_at(record, flags_at, flags_bytes, signed: false)
        columns, rows = piece_size(record, flags)
        FramePiece.new(x: number_at(record, x_at, position_bytes, signed: true),
                       y: number_at(record, y_at, position_bytes, signed: true), tile: first_tile(record),
                       mirrored: flag?(flags, mirrored_bit), upside_down: flag?(flags, upside_down_bit),
                       columns: columns, rows: rows)
      end

      # The tile +piece+ shows at +column+ and +row+ of itself (0 first), before it is turned.
      def piece_tile(piece, column, row)
        case tile_order
        when :down_columns then piece.tile + (column * piece.rows) + row
        when :across_rows then piece.tile + (row * piece.columns) + column
        else piece.tile + (row * row_tiles) + column
        end
      end

      private

      def first_tile(record)
        tile = number_at(record, tile_at, tile_bytes, signed: false)
        tile &= (1 << tile_bits) - 1 if tile_bits
        tile + (tile_row_at ? record.fetch(tile_row_at) * row_tiles : 0)
      end

      # How many tiles a piece is across and down.
      def piece_size(record, flags)
        return (flag?(flags, big_bit) ? [2, 2] : [1, 1]) unless size_at

        size = record.fetch(size_at)
        mask = (1 << size_bits) - 1
        [((size >> columns_bit) & mask) + 1, ((size >> rows_bit) & mask) + 1]
      end

      # The number of +width+ bytes from byte +at+ of +bytes+, in the original's byte order.
      def number_at(bytes, at, width, signed:)
        parts = bytes[at, width]
        parts = parts.reverse unless high_byte_first
        value = parts.reduce(0) { |sum, byte| (sum << 8) | byte }
        top = 1 << ((width * 8) - 1)
        signed && value >= top ? value - (top * 2) : value
      end

      def flag?(flags, bit) = !bit.nil? && flags[bit] == 1

      def refuse_bad_widths!(widths, high_byte_first)
        unless widths.all? { |width| [1, 2].include?(width) }
          raise ArgumentError, "A frame layout needs count_bytes:, position_bytes:, tile_bytes: and flags_bytes: each 1 " \
                               "or 2. Got #{widths.inspect}."
        end
        return if widths.all?(1) ? [nil, true, false].include?(high_byte_first) : [true, false].include?(high_byte_first)

        raise ArgumentError, "A frame layout with a part of two bytes needs high_byte_first:. Give true when the " \
                             "original keeps the high byte first, as a Genesis game does. Give false when it keeps " \
                             "the low byte first."
      end

      def refuse_bad_places!(piece_bytes, widths_by_place)
        places = widths_by_place.reject { |at, _| at.nil? }
        return if piece_bytes.is_a?(Integer) && piece_bytes.positive? &&
                  places.all? { |at, width| at.is_a?(Integer) && !at.negative? && at + width <= piece_bytes }

        raise ArgumentError, "A frame layout needs piece_bytes:, the bytes a piece takes, and each _at: a byte of the " \
                             "piece from 0 to piece_bytes - 1. A part of two bytes must end inside the piece too. Got " \
                             "piece_bytes: #{piece_bytes.inspect} and places #{places.keys.inspect}."
      end

      def refuse_bad_bits!(counted, bits, flags_bytes, row_tiles, tile_bits, tile_bytes)
        top_bit = (flags_bytes * 8) - 1
        unless bits.all? { |bit| bit.is_a?(Integer) && bit.between?(0, top_bit) } && [true, false].include?(counted) &&
               row_tiles.is_a?(Integer) && row_tiles.positive?
          raise ArgumentError, "A frame layout needs each _bit: from 0 to #{top_bit}, counted: true or false, and " \
                               "row_tiles: a whole number 1 or more."
        end
        return if tile_bits.nil? || (tile_bits.is_a?(Integer) && tile_bits.between?(1, tile_bytes * 8))

        raise ArgumentError, "A frame layout needs tile_bits: from 1 to #{tile_bytes * 8}, the low bits that are the " \
                             "tile's number. Got #{tile_bits.inspect}."
      end

      TILE_ORDERS = %i[down_columns across_rows].freeze

      def refuse_bad_size!(size_at, size_places, size_bits, tile_order, big_bit)
        if size_at.nil?
          return if size_places.none? && tile_order.nil?

          raise ArgumentError, "A frame layout was given columns_bit:, rows_bit: or tile_order: and no size_at:. These " \
                               "are for a piece of several tiles each way. Give size_at:, the byte that holds its size."
        end
        unless big_bit.nil?
          raise ArgumentError, "A frame layout was given size_at: and big_bit:. A piece has its size from one of " \
                               "them. Give size_at: or big_bit:, not the two."
        end
        unless size_bits.is_a?(Integer) && size_bits.between?(1, 3) &&
               size_places.all? { |bit| bit.is_a?(Integer) && !bit.negative? && bit + size_bits <= 8 }
          raise ArgumentError, "A frame layout with size_at: needs columns_bit: and rows_bit:, the lowest bit of each " \
                               "number in the size byte, and size_bits: from 1 to 3. Each number must end inside the " \
                               "byte. Got columns_bit: #{size_places[0].inspect}, rows_bit: #{size_places[1].inspect} " \
                               "and size_bits: #{size_bits.inspect}."
        end
        return if TILE_ORDERS.include?(tile_order)

        raise ArgumentError, "A frame layout with size_at: needs tile_order:. Give :down_columns when the tile after " \
                             "a piece's first is below it, as on a Genesis. Give :across_rows when it is to the " \
                             "right. Got #{tile_order.inspect}."
      end
    end
  end
end
