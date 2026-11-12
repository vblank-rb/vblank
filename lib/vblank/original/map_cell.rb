# frozen_string_literal: true

module VBlank
  module Original
    # ONE CELL OF A BACKGROUND'S MAP IN A DATA PACK, a record of VBlank's own, four bytes, the same
    # whatever console the original ran on:
    #
    #   0-1   tile        which tile, counted from the first tile of the background's `tiles:`, low
    #                     byte first. A second bank of video memory is more tiles of the same slot:
    #                     a Color tile in bank 1 is tile 384 on, where the slot holds bank 0's 384
    #                     tiles first.
    #   2     bank        which bank of colours of the background's `colors:` slot, 0 first
    #   3     turns       MIRRORED (left to right) and UPSIDE_DOWN; the other bits 0
    #
    # Each part is a field of its own and is as wide as the most any console VBlank lowers to
    # needs: the Genesis names 2048 tiles and the Advance sixteen banks, and the PlayStation more of
    # both. A cell is one tile, 8x8 pixels. A bit a console keeps for itself, like a priority, is
    # left out: a background's layer says where it is drawn, and no lowering reads one.
    #
    # WHY A RECORD OF VBLANK'S OWN. Each console packs a cell into bits of its own (the Advance's
    # tile in bits 0 to 9; the Color's in a map of its own, with its bank, turns and video bank in a
    # second map of attribute bytes), and a map read in the original's own layout makes VBlank learn
    # every console's. The port's unpacking routine (`slots.fill_from_copy`) already reads the
    # original's maps, so it writes each cell here instead (SlotBytes#write_cell), and a background
    # reads this record whatever the original was. A map kept as the Advance, the Super Nintendo or
    # the Genesis keeps it can still be read as it is (Console::OriginalFormats#map_words).
    module MapCell
      BYTES = 4
      MIRRORED = 1
      UPSIDE_DOWN = 2

      # The record read as one number of four bytes, low byte first, in the terms every reader of a
      # map already takes (Console::MapWordFormat): the build, the interpreter (IR::StartFile) and
      # each runtime's rg_start_file_fill_background read it as they read any console's cell.
      FORMAT = Console::MapWordFormat.new(tile_bits: 16, mirror_bit: 24, flip_bit: 25, bank_at: 16, bank_bits: 8,
                                          row_tiles: nil, cell_bytes: BYTES)
      NUMBER_FORMAT = Console::LOW_BYTE_FIRST_NUMBERS

      # The record's BYTES bytes, in order. Each part is a number, or a value of the game's in an
      # unpacking routine, of which whatever takes it keeps the low eight bits. +mirrored+ and
      # +upside_down+ are true or false, or a number of which the lowest bit is read (`(attributes
      # >> 5) & 1`).
      def self.bytes(tile:, bank: 0, mirrored: false, upside_down: false)
        turns = (turn_bit(mirrored) * MIRRORED) | (turn_bit(upside_down) * UPSIDE_DOWN)
        [tile, tile >> 8, bank, turns]
      end

      # 1 or 0 for a turn given as true or false, and a number's lowest bit otherwise.
      def self.turn_bit(turn)
        case turn
        when true then 1
        when false, nil then 0
        else turn & 1
        end
      end
      private_class_method :turn_bit

      # ONE CELL AS PLAIN NUMBERS, for .bytes_of.
      Cell = Data.define(:tile, :bank, :mirrored, :upside_down) do
        def initialize(tile:, bank: 0, mirrored: false, upside_down: false) = super
      end

      # +cells+ (each a Cell) as the bytes of a slot, for a port's tests and a routine of Ruby that
      # writes a slot whole. A part past its field keeps its low bits, as written by the routine.
      def self.bytes_of(cells)
        cells.flat_map { |cell| bytes(tile: cell.tile, bank: cell.bank, mirrored: cell.mirrored, upside_down: cell.upside_down) }
             .pack("C*")
      end
    end
  end
end
