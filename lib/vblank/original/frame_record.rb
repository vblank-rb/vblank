# frozen_string_literal: true

module VBlank
  module Original
    # A FRAME OF A SPRITE AS THE DATA PACK KEEPS IT: a record of VBlank's own, one fixed layout
    # whatever the original. Every original keeps a frame its own way, and a port says how with an
    # Original::FrameLayout. Only the pack's unpacking reads a frame that way: it writes each frame
    # the game names again as the record below (FrameRewrite, as game code), and everything that
    # draws a pose reads the record and knows no layout: the build that holds the pack
    # (Builder::PackPoses), the interpreter (IR::StartFile) and the C, JavaScript and Ruby runtimes
    # (rg_start_file_fill_pose in each). So a layout no original has had before is taught to
    # FrameLayout alone.
    #
    # THE RECORD NAMES TILES, NEVER PIXELS. A piece says which tile of the pose's slot of tiles it
    # starts at, so a console that keeps a slot's tiles once for everything drawn from them still
    # does. Which bank of the original's colours a piece is drawn from is in the record too: that
    # is the original's data, not its layout.
    #
    # THE LAYOUT, every number low byte first. This is the one place it is written down: the Ruby
    # that writes and reads a record takes it from the constants here, and each runtime's reader
    # names this file beside the same offsets.
    #
    #   A FRAME          HEADER_BYTES, then its pieces, the one in front first
    #     0  2 bytes     pieces held: how many pieces follow
    #     2  2 bytes     pieces named: how many the original's frame says it has (more than are
    #                    held where the frame ran past its slot)
    #
    #   A PIECE          PIECE_BYTES
    #     0  2 bytes     x, signed, from the object's place
    #     2  2 bytes     y, signed, from the object's place
    #     4  2 bytes     its first tile, counted from the first tile of the pose's `tiles:`
    #     6  2 bytes     column step: how many tiles on the tile one column to the right is
    #     8  2 bytes     row step: how many tiles on the tile one row down is
    #    10  1 byte      columns: how many tiles across it is
    #    11  1 byte      rows: how many tiles down it is
    #    12  1 byte      turns: MIRRORED and UPSIDE_DOWN, the whole piece turned as one
    #    13  1 byte      0
    #    14  2 bytes     bank: which bank of the original's colours it is drawn from, 0 where its
    #                    layout names none
    #
    # The tile at column c and row r of a piece, before it is turned, is tile + c * column step +
    # r * row step. The two steps are how a console orders a sprite's tiles in its video memory,
    # worked out as the record is written, so a reader multiplies and adds and asks nothing.
    #
    # WHERE THE RECORDS ARE IN THE PACK: after its last slot (Pack), as a Section.
    module FrameRecord
      ENTRY_BYTES = 4
      HEADER_BYTES = 4
      PIECE_BYTES = 16
      MIRRORED = 1
      UPSIDE_DOWN = 2

      # Where each part of a piece is, counted from the piece's first byte.
      X_AT = 0
      Y_AT = 2
      TILE_AT = 4
      COLUMN_STEP_AT = 6
      ROW_STEP_AT = 8
      COLUMNS_AT = 10
      ROWS_AT = 11
      TURNS_AT = 12
      BANK_AT = 14

      # The highest number a part of two bytes holds: a tile, a step or a count past it is kept as it.
      MOST = 0xFFFF

      # ONE PIECE OF A FRAME. As a record is read every part is a number. As one is written
      # (FrameLayout#piece_from) a part is a number in the build, and a value of the game's in the
      # unpacking, which works it out as it runs.
      Piece = Data.define(:x, :y, :tile, :column_step, :row_step, :columns, :rows, :turns, :bank) do
        def mirrored = turns.anybits?(MIRRORED)
        def upside_down = turns.anybits?(UPSIDE_DOWN)

        # The tile the piece shows at +column+ and +row+ of itself (0 first), before it is turned.
        def tile_at(column, row) = tile + (column * column_step) + (row * row_step)
      end

      # A FRAME AS READ BACK: how many pieces the original's frame names, and the pieces held.
      Frame = Data.define(:named, :pieces)

      # The bytes of +piece+, PIECE_BYTES of them in the order above. Each is a number, or a value
      # of the game's, of which whatever takes it keeps the low eight bits.
      def self.piece_bytes(piece)
        [piece.x, piece.x >> 8, piece.y, piece.y >> 8, piece.tile, piece.tile >> 8, piece.column_step, piece.column_step >> 8,
         piece.row_step, piece.row_step >> 8, piece.columns, piece.rows, piece.turns, 0, piece.bank, piece.bank >> 8]
      end

      # The bytes a frame starts with, HEADER_BYTES of them, as .piece_bytes gives a piece's.
      def self.header_bytes(held, named) = [held, held >> 8, named, named >> 8]

      # The frame whose record starts at byte +at+ of +bytes+ (a binary String). The bytes may be a
      # player's, so nothing in them is trusted: pieces are read while they end inside the bytes.
      def self.read(bytes, at = 0)
        held, named = bytes.byteslice(at, HEADER_BYTES).to_s.unpack("v2")
        return Frame.new(named: 0, pieces: []) unless named

        first = at + HEADER_BYTES
        held = [held, (bytes.bytesize - first) / PIECE_BYTES].min
        pieces = Array.new(held) do |piece|
          x, y, tile, column_step, row_step, columns, rows, turns, _, bank = bytes.byteslice(first + (piece * PIECE_BYTES), PIECE_BYTES).unpack("s<2v3C4v")
          Piece.new(x: x, y: y, tile: tile, column_step: column_step, row_step: row_step, columns: columns, rows: rows,
                    turns: turns, bank: bank)
        end
        Frame.new(named: named, pieces: pieces)
      end

      # ONE FRAME A GAME NAMES (`pack[:frames].frame(at, layout:)`): the +slot+ of bytes it is in (an
      # Original::Slot), the byte it starts at, how many pieces it has where its layout does not
      # say (nil where it does), its +layout+ (an Original::FrameLayout), and the values its pose
      # gives the layout's reader (FrameLayout#pose_values_for: numbers by name, none for a layout
      # of options). One frame given two sets of values is two sources, and two records.
      Source = Data.define(:slot, :at, :count, :layout, :pose) do
        def initialize(slot:, at:, count:, layout:, pose: {}) = super
        # Where the frame's first piece is in the slot.
        def first_piece_at = at + layout.count_bytes_before_pieces

        # The most pieces the frame can hold: those the game gave it, or as many as fit in the
        # slot after its count.
        def most_pieces = layout.counted ? [(slot.byte_size - first_piece_at) / layout.piece_bytes, 0].max : count

        # The frame's record (a binary String), read from +slot_bytes+, what its slot holds, with
        # room for +room+ pieces at most. A frame that names more pieces than its slot or the room
        # holds keeps those that fit, and still says how many it names.
        def record(slot_bytes, room: MOST)
          named = layout.counted ? layout.count_from { |byte| slot_bytes.getbyte(at + byte) } : count
          held = [named, most_pieces, room].min
          pieces = Array.new(held) do |piece|
            from = first_piece_at + (piece * layout.piece_bytes)
            FrameRecord.piece_bytes(layout.piece_from(pose: pose) { |byte| slot_bytes.getbyte(from + byte) })
          end
          [*FrameRecord.header_bytes(held, named), *pieces.flatten].pack("C*")
        end
      end

      # THE RECORDS OF EVERY FRAME A GAME NAMES, as the pack keeps them after its last slot:
      #
      #   a directory      ENTRY_BYTES for each frame, in the order the game named them: where the
      #                    frame's record starts, counted from the section's first byte, or 0 for a
      #                    frame with no record
      #   the records      one after another, in the same order
      #   zeros            to the section's size
      #
      # A frame that starts with its count has as many pieces as the player's copy says, so where a
      # record starts is known only once the frames before it are written: the directory says. The
      # section's SIZE follows from the game's own words alone (#size), as every slot's does, since
      # a build that leaves its pack out must know the file's size: the pieces a game gave a frame,
      # and for the frames that say their own count as many pieces as their slot could hold between
      # them. Frames laid over each other could ask for more; a record that does not fit keeps the
      # pieces that do, and one with no room for its header has none (entry 0), which draws nothing.
      # Frames of one slot read with different pose values are each a slot's worth, since one
      # frame given two sets of values is two records.
      Section = Data.define(:sources) do
        # The section's size in bytes.
        def size
          return 0 if sources.empty?

          pieces = sources.group_by { |source| [source.slot.name, source.layout, source.pose] }.sum do |(_, layout), group|
            counted, given = group.partition { |source| source.layout.counted }
            given.sum(&:most_pieces) + [counted.sum(&:most_pieces), group.first.slot.byte_size / layout.piece_bytes].min
          end
          (sources.length * (ENTRY_BYTES + HEADER_BYTES)) + (pieces * PIECE_BYTES)
        end

        # Where the directory's entry for frame +index+ is, and where the first record starts.
        def entry_at(index) = index * ENTRY_BYTES
        def records_at = sources.length * ENTRY_BYTES

        # How many pieces a record starting at +at+ has room for; below zero where its header does
        # not fit.
        def room_at(at) = (size - at - HEADER_BYTES).div(PIECE_BYTES)

        # The section's bytes, each frame read from its slot in +slot_bytes+ (by the slot's name):
        # what the pack's unpacking writes (FrameRewrite), worked out here by the build that holds
        # the pack.
        def bytes(slot_bytes)
          out = records_at
          directory = []
          records = sources.map do |source|
            room = room_at(out)
            next directory << 0 if room.negative?

            directory << out
            source.record(slot_bytes.fetch(source.slot.name), room: room).tap { |record| out += record.bytesize }
          end
          [directory.pack("V*"), *records.grep(String)].join.b.ljust(size, "\0".b)
        end
      end

      # The record of the frame whose directory entry is at byte +entry_at+ of +bytes+ (a whole
      # pack file), in a section that starts at byte +section_at+: an empty frame where the entry
      # names none, or names a place outside the file.
      def self.read_entry(bytes, entry_at:, section_at:)
        offset = bytes.byteslice(entry_at, ENTRY_BYTES).unpack1("V")
        return Frame.new(named: 0, pieces: []) if offset.nil? || offset.zero?

        read(bytes, section_at + offset)
      end
    end
  end
end
