# frozen_string_literal: true

module VBlank
  module Original
    # HOW AN ORIGINAL KEEPS ONE FRAME OF A SPRITE: a list of pieces, each a few bytes saying where
    # the piece sits, which tile it shows, and whether it is turned or big. A retail game copies a
    # frame's pieces into the console's sprite table each time a pose changes, adding the object's
    # place. The record is the game's own, so the port describes it here, by where each part is,
    # and a pose is read from it (`image ..., frame: pack[:frames].frame(at, layout: FRAME)`).
    #
    # ONLY THE PACK'S UNPACKING READS A FRAME THIS WAY. It writes each frame a game names again as
    # a record of VBlank's own (FrameRecord), one layout whatever the original's, and the build,
    # the interpreter and every runtime read that. So a way of keeping a frame that no original
    # here has had before is taught to this class alone (#piece_from), and to nothing that draws.
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
    # Other bits are not read, and a piece's colours are the pose's `colors:` list, as a retail
    # game takes its sprite's colours from the object, unless the layout names a bank (below).
    #
    # A PIECE THAT NAMES ITS BANK OF COLOURS. A console's sprite entry says which of its banks of
    # colours the piece is drawn from, and an original that keeps the entry keeps that too (a
    # Genesis game in bits 13 and 14 of the tile word, its four lines of colours). +bank_bit+ is
    # the lowest bit of that number at +flags_at+ and +bank_bits+ how many bits it is:
    # `bank_bit: 13, bank_bits: 2`. A pose given a whole slot of colours then takes its colours
    # from the bank its pieces name (Builder::PackPoses); one given a list is drawn in that list,
    # and the bank is not read.
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
    # A TILE'S NUMBER KEPT IN TWO PLACES. A Super Nintendo's sprite entry keeps a tile's low eight
    # bits in a byte of their own and its ninth among the flags, and an original that keeps the
    # entry keeps that too. +tile_high_bit+ is the lowest of those high bits at +flags_at+ and
    # +tile_high_bits+ how many there are: `tile_at: 2, flags_at: 3, tile_high_bit: 0,
    # tile_high_bits: 1`. They go above the bits read at +tile_at+ (above +tile_bits+ of them,
    # where the layout names that).
    #
    # A PIECE OF SEVERAL TILES EACH WAY. The byte at +size_at+ holds two numbers of +size_bits+
    # bits each: how many tiles the piece is across, less one, from bit +columns_bit+ up, and how
    # many down, less one, from bit +rows_bit+ up. +tile_order+ says how the piece's tiles follow
    # its first in sprite memory, which is the console's choice and not the game's:
    # +:down_columns+ where t + 1 is BELOW t and the next column starts at t + rows, and
    # +:across_rows+ where t + 1 is right of t and the next row starts at t + columns. A piece
    # that is mirrored or upside down is turned whole, so its columns or rows change places too,
    # as the console turns a sprite.
    #
    # A PIECE WHOSE SIZE IS THE GAME BOY ADVANCE'S OWN PAIR. The Advance's sprite entry does not
    # keep a piece's width and height: it keeps a shape (0 square, 1 wide, 2 tall) and a size of
    # that shape (0 to 3), and the console reads the two through a table of its own, in tiles
    # across by down:
    #
    #   shape 0, square:  1x1  2x2  4x4  8x8
    #   shape 1, wide:    2x1  4x1  4x2  8x4
    #   shape 2, tall:    1x2  1x4  2x4  4x8
    #
    # An original that keeps a frame as the console's entries keeps the pair too. +shape_bit+ is
    # the lowest of the shape's two bits at +flags_at+ and +shape_size_bit+ the lowest of the
    # size's two: `shape_bit: 6, shape_size_bit: 4`. +tile_order+ must be given with them, as with
    # +size_at+ (on the Advance it is :across_rows, its one-dimensional sprite mapping), and they
    # take the place of +big_bit+ and +size_at+.
    FrameLayout = Data.define(:piece_bytes, :counted, :x_at, :y_at, :tile_at, :tile_row_at, :row_tiles, :flags_at,
                              :mirrored_bit, :upside_down_bit, :big_bit, :high_byte_first, :count_bytes,
                              :position_bytes, :tile_bytes, :tile_bits, :flags_bytes, :size_at, :columns_bit,
                              :rows_bit, :size_bits, :tile_order, :bank_bit, :bank_bits, :tile_high_bit, :tile_high_bits,
                              :shape_bit, :shape_size_bit) do
      def initialize(piece_bytes:, counted:, x_at:, y_at:, tile_at:, flags_at:, mirrored_bit: nil, upside_down_bit: nil,
                     tile_row_at: nil, row_tiles: 16, big_bit: nil, high_byte_first: nil, count_bytes: 1,
                     position_bytes: 1, tile_bytes: 1, tile_bits: nil, flags_bytes: 1, size_at: nil, columns_bit: nil,
                     rows_bit: nil, size_bits: 2, tile_order: nil, bank_bit: nil, bank_bits: nil, tile_high_bit: nil,
                     tile_high_bits: nil, shape_bit: nil, shape_size_bit: nil)
        widths = [count_bytes, position_bytes, tile_bytes, flags_bytes]
        refuse_bad_widths!(widths, high_byte_first)
        refuse_bad_places!(piece_bytes, { x_at => position_bytes, y_at => position_bytes, tile_at => tile_bytes,
                                          flags_at => flags_bytes, tile_row_at => 1, size_at => 1 })
        refuse_bad_bits!(counted, [mirrored_bit, upside_down_bit, big_bit].compact, flags_bytes, row_tiles, tile_bits,
                         tile_bytes)
        if shape_bit || shape_size_bit
          refuse_bad_shape!(shape_bit, shape_size_bit, flags_bytes, tile_order, [size_at, columns_bit, rows_bit, big_bit])
        else
          refuse_bad_size!(size_at, [columns_bit, rows_bit], size_bits, tile_order, big_bit)
        end
        refuse_bad_bank!(bank_bit, bank_bits, flags_bytes)
        refuse_bad_tile_high_bits!(tile_high_bit, tile_high_bits, flags_bytes)
        super
      end

      # Whether a piece of this layout names the bank of colours it is drawn from.
      def names_bank? = !bank_bit.nil?

      # How many bytes of a frame come before its first piece: its count, where it has one.
      def count_bytes_before_pieces = counted ? count_bytes : 0

      # WHAT READS A FRAME'S BYTES. The two methods below are the whole of how a layout is read,
      # and they are handed the bytes one at a time by a block: byte +at+ of the frame (#count_from)
      # or of the piece (#piece_from), 0 to 255. The build that holds the pack hands them numbers.
      # The pack's unpacking (FrameRewrite) hands them values of the game's, read from the pack as
      # it runs, and so gets back the sums that work each part out, as game code. So everything
      # here is arithmetic that reads the same on a number and on a game's value: shifts, masks and
      # sums, a value on the left of each, and never a test of what a byte holds. A part read twice
      # asks the block twice, since a game's value is made for one place in the routine.

      # How many pieces a frame says it has, from the bytes it starts with.
      def count_from(&byte) = part(0, count_bytes, &byte)

      # One piece as the pack keeps it (a FrameRecord::Piece).
      def piece_from(&byte)
        FrameRecord::Piece.new(
          x: signed(part(x_at, position_bytes, &byte), position_bytes), y: signed(part(y_at, position_bytes, &byte), position_bytes),
          tile: first_tile(&byte), column_step: column_step(&byte), row_step: row_step(&byte),
          columns: columns(&byte), rows: rows(&byte),
          turns: sum_of(flag(mirrored_bit, FrameRecord::MIRRORED, &byte), flag(upside_down_bit, FrameRecord::UPSIDE_DOWN, &byte)),
          bank: names_bank? ? (flags(&byte) >> bank_bit) & ((1 << bank_bits) - 1) : 0
        )
      end

      private

      def first_tile(&byte)
        tile = part(tile_at, tile_bytes, &byte)
        tile &= (1 << tile_bits) - 1 if tile_bits
        tile |= ((flags(&byte) >> tile_high_bit) & ((1 << tile_high_bits) - 1)) << (tile_bits || (tile_bytes * 8)) if tile_high_bit
        tile += yield(tile_row_at) * row_tiles if tile_row_at
        tile.clamp(0, FrameRecord::MOST)
      end

      # HOW A PIECE'S TILES FOLLOW ITS FIRST, as the two steps a record keeps: how many tiles on
      # the tile one column to the right is, and the tile one row down.
      def column_step(&byte) = tile_order == :down_columns ? rows(&byte) : 1

      def row_step(&byte)
        case tile_order
        when :down_columns then 1
        when :across_rows then columns(&byte)
        else [row_tiles, FrameRecord::MOST].min
        end
      end

      # How many tiles a piece is across, and down.
      def columns(&byte)
        if shape_bit then power_of_two { shape_columns_power(&byte) }
        elsif size_at then size_number(columns_bit, &byte)
        else big_or_one(&byte)
        end
      end

      def rows(&byte)
        if shape_bit then power_of_two { shape_rows_power(&byte) }
        elsif size_at then size_number(rows_bit, &byte)
        else big_or_one(&byte)
        end
      end

      def size_number(bit) = ((yield(size_at) >> bit) & ((1 << size_bits) - 1)) + 1

      # THE ADVANCE'S TABLE OF SPRITE SIZES, AS SUMS. Each side of every entry is a power of two,
      # 1 to 8 tiles, so the table is read as which power (0 to 3) each side is. A square's sides
      # are both the size's own power, +a+. A wide piece's columns are one power more at sizes 0
      # and 1 and the same at 2 and 3 (a + 1, less 1 where bit 1 of the size is set: 1, 2, 2, 3),
      # and its rows one less, except at size 0 where they stay at 1 (a, less 1 where the size is
      # not 0: 0, 0, 1, 2). A tall piece is the wide one turned: the same two rules, the other way.
      #
      # It is sums and masks and not a lookup, since a lookup by a game's value cannot be written
      # here (see WHAT READS A FRAME'S BYTES above). The console has no fourth shape (both bits
      # set), and a build cannot refuse one, since the shape is in the player's file. A piece that
      # names it is read as a square of its size: a size the console has, and drawn like any
      # other piece, so what of it falls outside the picture is not drawn.
      def shape_columns_power(&byte) = shape_size(&byte) + (wide(&byte) & one_more_power(&byte)) - (tall(&byte) & one_less_power(&byte))
      def shape_rows_power(&byte) = shape_size(&byte) + (tall(&byte) & one_more_power(&byte)) - (wide(&byte) & one_less_power(&byte))

      def shape(&byte) = (flags(&byte) >> shape_bit) & 3
      def shape_size(&byte) = (flags(&byte) >> shape_size_bit) & 3

      # 1 where the piece is wide (shape 1), 0 where not.
      def wide(&byte) = shape(&byte) & ((shape(&byte) >> 1) ^ 1) & 1
      # 1 where the piece is tall (shape 2), 0 where not.
      def tall(&byte) = (shape(&byte) >> 1) & (shape(&byte) ^ 1) & 1

      # 1 where the long side of a wide or tall piece is one power more than its size's (sizes 0
      # and 1), 0 where it is the same (sizes 2 and 3).
      def one_more_power(&byte) = (shape_size(&byte) >> 1) ^ 1
      # 1 where the short side is one power less than its size's (sizes 1 to 3), 0 at size 0.
      def one_less_power(&byte) = (shape_size(&byte) | (shape_size(&byte) >> 1)) & 1

      # 2 to the power the block gives (0 to 3): one more than its low bit, moved up two places
      # where its high bit is set. The block is asked twice, since a game's value is made for one
      # place, and the number moved is on the left of the shift, as a game's value must be.
      def power_of_two = ((yield & 1) + 1) << (yield & 2)

      # Two tiles a side where the piece's big bit is set, and one where it is not or there is none.
      def big_or_one(&byte) = big_bit ? ((flags(&byte) >> big_bit) & 1) + 1 : 1

      def flags(&byte) = part(flags_at, flags_bytes, &byte)

      # +worth+ where bit +bit+ of the flags is set, and 0 where it is not or the layout has no such bit.
      def flag(bit, worth, &byte) = bit ? ((flags(&byte) >> bit) & 1) * worth : 0

      # The number of +width+ bytes (1 or 2) from byte +at+, in the original's byte order, 0 or more.
      def part(at, width)
        return yield(at) if width == 1

        high, low = high_byte_first ? [at, at + 1] : [at + 1, at]
        (yield(high) << 8) | yield(low)
      end

      # +number+ (0 or more, +width+ bytes wide) read as one that can be below zero.
      def signed(number, width)
        top = 1 << ((width * 8) - 1)
        (number ^ top) - top
      end

      # The sum of +terms+, each a number or a game's value, with a value on the left of every sum.
      def sum_of(*terms)
        numbers, values = terms.partition { |term| term.is_a?(Integer) }
        # Must fold with +, not Array#sum: sum starts from Ruby's 0, and a term may be a game's value.
        [*values, numbers.sum].reduce { |sum, term| sum + term }
      end

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

      def refuse_bad_bank!(bank_bit, bank_bits, flags_bytes)
        return if bank_bit.nil? && bank_bits.nil?

        top_bit = (flags_bytes * 8) - 1
        return if bank_bit.is_a?(Integer) && bank_bits.is_a?(Integer) && bank_bits.positive? && !bank_bit.negative? &&
                  bank_bit + bank_bits - 1 <= top_bit

        raise ArgumentError, "A frame layout that names a piece's bank of colors needs bank_bit:, the lowest bit of the " \
                             "bank's number at flags_at:, and bank_bits:, how many bits the number is. The number must " \
                             "end at bit #{top_bit} or lower. Got bank_bit: #{bank_bit.inspect} and bank_bits: " \
                             "#{bank_bits.inspect}."
      end

      def refuse_bad_tile_high_bits!(tile_high_bit, tile_high_bits, flags_bytes)
        return if tile_high_bit.nil? && tile_high_bits.nil?

        top_bit = (flags_bytes * 8) - 1
        return if tile_high_bit.is_a?(Integer) && tile_high_bits.is_a?(Integer) && tile_high_bits.positive? &&
                  !tile_high_bit.negative? && tile_high_bit + tile_high_bits - 1 <= top_bit

        raise ArgumentError, "A frame layout that keeps a tile's high bits among the flags needs tile_high_bit:, the " \
                             "lowest of those bits at flags_at:, and tile_high_bits:, how many bits there are. The bits " \
                             "must end at bit #{top_bit} or lower. Got tile_high_bit: #{tile_high_bit.inspect} and " \
                             "tile_high_bits: #{tile_high_bits.inspect}."
      end

      TILE_ORDERS = %i[down_columns across_rows].freeze

      # +other_sizes+ is size_at:, columns_bit:, rows_bit: and big_bit:, none of which may be given too.
      def refuse_bad_shape!(shape_bit, shape_size_bit, flags_bytes, tile_order, other_sizes)
        top_bit = (flags_bytes * 8) - 1
        unless [shape_bit, shape_size_bit].all? { |bit| bit.is_a?(Integer) && !bit.negative? && bit + 1 <= top_bit }
          raise ArgumentError, "A frame layout that reads a piece's size as the Game Boy Advance's shape and size needs " \
                               "shape_bit: and shape_size_bit:, the lowest bit of each two-bit number at flags_at:. Each " \
                               "number must end at bit #{top_bit} or lower. Got shape_bit: #{shape_bit.inspect} and " \
                               "shape_size_bit: #{shape_size_bit.inspect}."
        end
        unless other_sizes.none?
          raise ArgumentError, "A frame layout was given shape_bit: and shape_size_bit: with size_at:, columns_bit:, " \
                               "rows_bit: or big_bit:. A piece has its size from one of them. Give shape_bit: and " \
                               "shape_size_bit:, or the others, not both."
        end
        return if TILE_ORDERS.include?(tile_order)

        raise ArgumentError, "A frame layout with shape_bit: and shape_size_bit: needs tile_order:. Give :across_rows " \
                             "when the tile after a piece's first is to its right, as on a Game Boy Advance. Got " \
                             "#{tile_order.inspect}."
      end

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
