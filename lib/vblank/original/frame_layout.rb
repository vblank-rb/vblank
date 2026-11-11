# frozen_string_literal: true

module VBlank
  module Original
    # ONE PIECE OF A FRAME, as its record says (FrameLayout#piece_of): where it sits from the
    # object's place, which tile it starts at, turned how, and whether it is big.
    FramePiece = Data.define(:x, :y, :tile, :mirrored, :upside_down, :big)

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
    # +piece_bytes+ is how many bytes a piece takes. +counted+ is true where the frame's first byte
    # is how many pieces follow; false where the game names the count (`frame(at, count:, ...)`).
    # Each +_at+ is a byte of a piece, counted from its first: x and y are signed, from the
    # object's place, and the tile is the byte at +tile_at+, plus +row_tiles+ times the byte at
    # +tile_row_at+ where the original names a row of sprite memory apart (nil where it does not).
    # The byte at +flags_at+ holds the bits: +mirrored_bit+ and +upside_down_bit+ (nil for an
    # original whose pieces never turn), and +big_bit+ for a piece of 16x16, which is the tiles t,
    # t + 1, t + row_tiles and t + row_tiles + 1 (nil for an original whose pieces are all 8x8).
    # Other bits are not read: a piece's bank of colours is the pose's `colors:` list, as a retail
    # game takes its sprite's colours from the object.
    FrameLayout = Data.define(:piece_bytes, :counted, :x_at, :y_at, :tile_at, :tile_row_at, :row_tiles, :flags_at,
                              :mirrored_bit, :upside_down_bit, :big_bit) do
      def initialize(piece_bytes:, counted:, x_at:, y_at:, tile_at:, flags_at:, mirrored_bit: nil, upside_down_bit: nil,
                     tile_row_at: nil, row_tiles: 16, big_bit: nil)
        refuse_bad_layout!(piece_bytes, counted, [x_at, y_at, tile_at, flags_at, tile_row_at].compact,
                           [mirrored_bit, upside_down_bit, big_bit].compact, row_tiles)
        super
      end

      # The piece +record+ (its +piece_bytes+ bytes, as Integers) holds (a FramePiece).
      def piece_of(record)
        flags = record.fetch(flags_at)
        FramePiece.new(x: signed(record.fetch(x_at)), y: signed(record.fetch(y_at)),
                       tile: record.fetch(tile_at) + (tile_row_at ? record.fetch(tile_row_at) * row_tiles : 0),
                       mirrored: flag?(flags, mirrored_bit), upside_down: flag?(flags, upside_down_bit),
                       big: flag?(flags, big_bit))
      end

      private

      def signed(byte) = byte >= 0x80 ? byte - 0x100 : byte

      def flag?(flags, bit) = !bit.nil? && flags[bit] == 1

      def refuse_bad_layout!(piece_bytes, counted, places, bits, row_tiles)
        unless piece_bytes.is_a?(Integer) && piece_bytes.positive? &&
               places.all? { |at| at.is_a?(Integer) && at.between?(0, piece_bytes - 1) }
          raise ArgumentError, "A frame layout needs piece_bytes:, the bytes a piece takes, and each _at: a byte of the " \
                               "piece from 0 to piece_bytes - 1. Got piece_bytes: #{piece_bytes.inspect} and places " \
                               "#{places.inspect}."
        end
        unless bits.all? { |bit| bit.is_a?(Integer) && bit.between?(0, 7) } && [true, false].include?(counted) &&
               row_tiles.is_a?(Integer) && row_tiles.positive?
          raise ArgumentError, "A frame layout needs each _bit: from 0 to 7, counted: true or false, and row_tiles: a " \
                               "whole number 1 or more."
        end
      end
    end
  end
end
