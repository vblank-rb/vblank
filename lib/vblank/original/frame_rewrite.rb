# frozen_string_literal: true

module VBlank
  module Original
    # EACH FRAME A GAME NAMES, WRITTEN AGAIN AS A RECORD OF VBLANK'S OWN (FrameRecord), by the
    # pack's unpacking. A frame's slot holds the original's bytes, kept the original's way, and a
    # game says where a frame is in it and how it is kept (`pack[:frames].frame(at, layout: FRAME)`).
    # Once every slot is filled, copied as it is or by the game's routine, this reads each such
    # frame from the pack's own bytes and writes its record after the last slot
    # (FrameRecord::Section). Nothing that draws a pose then reads an original's layout.
    #
    # It is game code, as the rest of an unpacking is, so the interpreter and every runtime play
    # it and none of them is taught a layout: the layout is asked for each part of a piece as
    # sums of the piece's bytes (FrameLayout#piece_from), and those sums are the routine. The
    # build that holds the pack asks the layout the same question with numbers
    # (FrameRecord::Section#bytes), and the two must write the same bytes.
    #
    # The frames of one slot kept one way are a table of where each starts, and one loop over it.
    # This file is read as game code, so each `if` on a test the routine makes is a branch in it.
    class FrameRewrite
      # How many pieces are written between one wait for the next frame and the next. A wait costs
      # far more than a piece does, so they are few: a routine must wait now and then so a shell
      # can show it is alive (Unpacking#run_as_ruby), and so the interpreter's count of steps in
      # one frame stays well inside what it allows. A few hundred frames come to a few waits.
      PIECES_A_WAIT = 512

      # +pack+ is the list of the pack's bytes and +section+ the FrameRecord::Section to write
      # from byte +section_at+ of it; +slot_places+ is where each slot starts in the list, by name;
      # +wait+ makes the routine wait for the next frame.
      def initialize(builder, pack:, section:, section_at:, slot_places:, wait:)
        @builder = builder
        @pack = pack
        @section = section
        @section_at = section_at
        @slot_places = slot_places
        @wait = wait
      end

      def emit
        return if @section.sources.empty?

        variable(:out).store!(@section_at + @section.records_at)
        groups = @section.sources.each_with_index.group_by { |source, _| [source.slot.name, source.layout] }
        groups.each_value.with_index { |entries, number| emit_frames(entries, number) }
      end

      private

      def variable(what) = (@variables ||= {})[what] ||= @builder.var(made_name(what), 0)

      def made_name(what) = Messages::MadeNames.make(:unpacking_part, part: :"frame_#{what}")

      def value_of(number) = DSL::Value.new(@builder, DSL::Value.node_for(number))

      # The byte at +at+ of the pack's list, 0 to 255.
      def pack_byte(at) = @pack[at] & 0xFF

      # +bytes+ written into the pack's list from +at+ on, the low eight bits of each.
      def emit_bytes(at, bytes)
        bytes.each_with_index { |byte, step| @pack[at + step] = byte }
      end

      # The frames of one slot kept one way (+entries+, each a FrameRecord::Source and its number
      # in the section): where each starts, the count the game gave it, its number, and the values
      # its pose gives the layout's reader, in the order the reader reads them (none for a layout
      # of options). Those are a row of the table, so one loop reads frames given different values.
      def emit_frames(entries, number)
        source = entries.first.first
        layout = source.layout
        names = layout.pose_names
        row = 3 + names.length
        slot_at = @slot_places.fetch(source.slot.name)
        rows = entries.flat_map { |frame, index| [frame.at, frame.count || 0, index, *names.map { |name| frame.pose.fetch(name) }] }
        frames = @builder.table(made_name(:"frames_#{number}"), rows, width: :word, signed: true)
        at = variable(:at)
        first = variable(:first)
        named = variable(:named)
        held = variable(:held)
        most = variable(:most)
        out = variable(:out)
        waited = variable(:pieces_since_wait)
        section_end = @section_at + @section.size
        @builder.repeat(entries.length) do |frame|
          at.store!(frames[frame * row] + slot_at)
          if layout.counted
            named.store!(layout.count_from { |byte| pack_byte(at + byte) })
          else
            named.store!(frames[(frame * row) + 1])
          end
          first.store!(at + layout.count_bytes_before_pieces)
          held.store!(named)
          if layout.counted
            most.store!((value_of(slot_at + source.slot.byte_size) - first) / layout.piece_bytes)
            if held > most
              held.store!(most)
            end
          end
          if out + FrameRecord::HEADER_BYTES <= section_end
            most.store!((value_of(section_end - FrameRecord::HEADER_BYTES) - out) / FrameRecord::PIECE_BYTES)
            if held > most
              held.store!(most)
            end
            emit_bytes(value_of(@section_at) + (frames[(frame * row) + 2] * FrameRecord::ENTRY_BYTES), entry_bytes(out - @section_at))
            emit_bytes(out, FrameRecord.header_bytes(held, named))
            out.increase!(FrameRecord::HEADER_BYTES)
            # Each value is read from the table again wherever the reader asks for it, as a byte is.
            pose = ->(name) { frames[(frame * row) + 3 + names.index(name)] }
            @builder.repeat(held) do |piece|
              emit_piece(layout, first + (piece * layout.piece_bytes), out, pose)
              out.increase!(FrameRecord::PIECE_BYTES)
            end
            waited.increase!(held + 1)
            if waited >= PIECES_A_WAIT
              waited.store!(0)
              @wait.call
            end
          end
        end
      end

      # A directory entry's bytes: +offset+, low byte first.
      def entry_bytes(offset)
        place = variable(:entry)
        place.store!(offset)
        [place, place >> 8, place >> 16, place >> 24]
      end

      # One piece, its bytes from +from+ in the pack's list, written as a record's at +to+. Each
      # part is worked out once into a variable, since a record keeps most parts in two bytes.
      # +pose+ makes the game's value of a pose value by its name.
      def emit_piece(layout, from, to, pose)
        start = variable(:piece_at)
        start.store!(from)
        read = layout.piece_from(pose: pose) { |byte| pack_byte(start + byte) }
        kept = read.to_h.to_h do |part, worked_out|
          next [part, worked_out] if worked_out.is_a?(Integer)

          held = variable(:"piece_#{part}")
          held.store!(worked_out)
          [part, held]
        end
        emit_bytes(to, FrameRecord.piece_bytes(FrameRecord::Piece.new(**kept)))
      end
    end
  end
end
