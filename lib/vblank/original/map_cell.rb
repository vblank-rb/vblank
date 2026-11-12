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
      # The most each part holds: a tile in two bytes, a bank in one.
      MOST_TILE = 0xFFFF
      MOST_BANK = 0xFF
      # Where the bank and the turns start, in the record read as one number.
      BANK_AT = 16
      TURNS_AT = 24

      # The record read as one number of four bytes, low byte first, in the terms every reader of a
      # map already takes (Console::MapWordFormat): the build, the interpreter (IR::StartFile) and
      # each runtime's rg_start_file_fill_background read it as they read any console's cell.
      FORMAT = Console::MapWordFormat.new(tile_bits: 16, mirror_bit: TURNS_AT, flip_bit: TURNS_AT + 1, bank_at: BANK_AT,
                                          bank_bits: 8, row_tiles: nil, cell_bytes: BYTES)
      NUMBER_FORMAT = Console::LOW_BYTE_FIRST_NUMBERS

      # The record's BYTES bytes, in order. Each part is a number, or a value of the game's in an
      # unpacking routine, of which whatever takes it keeps the low eight bits. +mirrored+ and
      # +upside_down+ are true or false, or a number of which the lowest bit is read (`(attributes
      # >> 5) & 1`).
      def self.bytes(tile:, bank: 0, mirrored: false, upside_down: false)
        turns = turns_of(mirrored, upside_down)
        [tile, tile >> 8, bank, turns]
      end

      # THE RECORD AS ONE NUMBER, as FORMAT reads it: `tile | bank << 16 | turns << 24`. It fits a
      # game's number, so a game keeps a cell in a variable or works one out, and a background of
      # map cells takes it in `set_cells:` and `set_cell`. +tile+ may be a value the game works out
      # (a letter read from a table, plus the font's first tile), and the rest are then added to it;
      # such a tile past MOST_TILE as the game runs runs into the bank. A tile or a bank given as a
      # number past its part is refused.
      def self.number(tile:, bank: 0, mirrored: false, upside_down: false)
        refuse_oversized_part!("A map cell was given", tile: tile, bank: bank)
        tile + ((bank << BANK_AT) | (turns_of(mirrored, upside_down) << TURNS_AT))
      end

      # A tile or a bank given as a number too big for its part would keep only its low bits, and
      # name another tile or bank than the one written. +subject+ starts the sentence: what was
      # given the part (`"The unpacking writes cell 3 of slot :map with"`).
      def self.refuse_oversized_part!(subject, tile:, bank:)
        [[:tile, tile, MOST_TILE], [:bank, bank, MOST_BANK]].each do |part, given, most|
          next unless given.is_a?(Integer) && !given.between?(0, most)

          raise ArgumentError, "#{subject} #{part} #{given}. A map cell holds a #{part} from 0 to #{most}. " \
                               "To fix this, give a #{part} from 0 to #{most}."
        end
      end

      def self.turns_of(mirrored, upside_down) = (turn_bit(mirrored) * MIRRORED) | (turn_bit(upside_down) * UPSIDE_DOWN)
      private_class_method :turns_of

      # 1 or 0 for a turn given as true or false, and a number's lowest bit otherwise.
      def self.turn_bit(turn)
        case turn
        when true then 1
        when false, nil then 0
        else turn & 1
        end
      end
      private_class_method :turn_bit

      # ONE CELL AS PLAIN NUMBERS, for .bytes_of, and for a cell a background of map cells is told
      # (`set_cells:`) and written (`set_cell`).
      Cell = Data.define(:tile, :bank, :mirrored, :upside_down) do
        def initialize(tile:, bank: 0, mirrored: false, upside_down: false) = super

        # The record as one number (MapCell.number).
        def number = MapCell.number(tile: tile, bank: bank, mirrored: mirrored, upside_down: upside_down)
      end

      # +cells+ (each a Cell) as the bytes of a slot, for a port's tests and a routine of Ruby that
      # writes a slot whole. A part past its field keeps its low bits, as written by the routine.
      def self.bytes_of(cells)
        cells.flat_map { |cell| bytes(tile: cell.tile, bank: cell.bank, mirrored: cell.mirrored, upside_down: cell.upside_down) }
             .pack("C*")
      end

      # Must stay below .number and .turn_bit, which it calls as the module loads.
      # The highest number a record can be: every part at its most, both turns.
      MOST_NUMBER = number(tile: MOST_TILE, bank: MOST_BANK, mirrored: true, upside_down: true)
    end
  end
end
