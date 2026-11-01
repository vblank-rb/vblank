# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE LISTS: a game's `list`, and every field of a pool, as the interpreter keeps them
          # (Reference::ListValue) — items added at the back and taken from either end, read and
          # written by index, and the game stopped, in the interpreter's words, by an index outside
          # the list, an item added to a full one or taken from an empty one.
          #
          # A list lives in work RAM (Memory#reserve): a header of four words — its capacity, where
          # its first item is, how many items it holds, and how far to shift a slot's number to get
          # its place in bytes (0, 1 or 2 for slots of 1, 2 or 4 bytes) — and then its slots. The items
          # go round the slots like a ring, so taking one from the front moves where the first
          # item is rather than every item after it.
          #
          # A slot narrower than a long keeps the low bits of what goes in and reads back with its top
          # bit as the sign: 200 in a byte slot reads -56, as the interpreter has it.
          #
          # Every routine is handed the list's address in D0 and is reached with JSR; its other
          # numbers are in D1, D2, D3... A0 points at the list while a routine works.
          module Lists
            CAPACITY = 0
            FRONT = 2
            LENGTH = 4
            SHIFT = 6
            HEADER = 8

            # How a table keeps its entries, by the number the lowering hands rt_list_copy: a signed
            # byte, an unsigned byte, a signed half, an unsigned half, a whole word.
            KEPT = { signed_byte: 0, byte: 1, signed_half: 2, half: 3, word: 4 }.freeze

            module_function

            def emit(asm, memory)
              emit_start(asm)
              emit_empty(asm)
              emit_push(asm)
              emit_drop(asm)
              emit_get_and_set(asm)
              emit_fill(asm)
              emit_copy(asm)
              emit_slot_access(asm)
              emit_faults(asm, memory)
            end

            # rt_lists_start: every list's header, from the table the lowering writes ("game_lists"):
            # each list's address (a long), its capacity and its shift (a word each), and an address of
            # nought after the last.
            def emit_start(asm)
              asm.label("rt_lists_start")
              asm.lea(asm.abs_l("game_lists"), asm.a(1))
              asm.label("rt_lists_start_next")
              asm.move(:l, asm.post(1), asm.d(0))
              asm.branch(:eq, "rt_lists_start_done")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:w, asm.post(1), asm.disp(0, CAPACITY))
              asm.move(:w, asm.post(1), asm.disp(0, SHIFT))
              asm.bra("rt_lists_start_next")
              asm.label("rt_lists_start_done")
              asm.rts
            end

            # rt_list_empty: no items. rt_list_at_capacity: as many as it holds, from its first slot
            # (rt_list_fill then says what they are). rt_list_length: D0 = how many it holds.
            def emit_empty(asm)
              asm.label("rt_list_empty")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.clr(:w, asm.disp(0, FRONT))
              asm.clr(:w, asm.disp(0, LENGTH))
              asm.rts

              asm.label("rt_list_at_capacity")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.clr(:w, asm.disp(0, FRONT))
              asm.move(:w, asm.disp(0, CAPACITY), asm.disp(0, LENGTH))
              asm.rts

              asm.label("rt_list_length")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.disp(0, LENGTH), asm.d(0))
              asm.rts
            end

            # rt_list_push(list, value): the value into the slot after the last item. A full list
            # stops the game.
            def emit_push(asm)
              asm.label("rt_list_push")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(1), asm.d(5))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, LENGTH), asm.d(2))
              asm.cmp(:w, asm.disp(0, CAPACITY), asm.d(2))
              asm.branch(:cs, "rt_list_push_room")
              asm.jmp(asm.abs_l("rt_list_full"))
              asm.label("rt_list_push_room")
              asm.jsr(asm.abs_l("rt_list_slot_of_offset"))
              asm.jsr(asm.abs_l("rt_list_write_slot"))
              asm.addq(:w, 1, asm.disp(0, LENGTH))
              asm.rts
            end

            # rt_list_drop(list, from): the first item taken (from 1) or the last (from 0). An empty
            # list stops the game.
            def emit_drop(asm)
              asm.label("rt_list_drop")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.tst(:w, asm.disp(0, LENGTH))
              asm.branch(:ne, "rt_list_drop_some")
              asm.jmp(asm.abs_l("rt_list_empty_fault"))
              asm.label("rt_list_drop_some")
              asm.subq(:w, 1, asm.disp(0, LENGTH))
              asm.tst(:l, asm.d(1))
              asm.branch(:eq, "rt_list_drop_done")
              asm.move(:w, asm.disp(0, FRONT), asm.d(2))
              asm.addq(:w, 1, asm.d(2))
              asm.cmp(:w, asm.disp(0, CAPACITY), asm.d(2))
              asm.branch(:cs, "rt_list_drop_front")
              asm.moveq(0, asm.d(2))
              asm.label("rt_list_drop_front")
              asm.move(:w, asm.d(2), asm.disp(0, FRONT))
              asm.label("rt_list_drop_done")
              asm.rts
            end

            # rt_list_get(list, index): D0 = the item. rt_list_set(list, index, value). An index
            # outside the list stops the game before anything is read or written.
            def emit_get_and_set(asm)
              asm.label("rt_list_get")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.jsr(asm.abs_l("rt_list_slot_of_index"))
              asm.jsr(asm.abs_l("rt_list_read_slot"))
              asm.rts

              asm.label("rt_list_set")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(2), asm.d(5))
              asm.jsr(asm.abs_l("rt_list_slot_of_index"))
              asm.jsr(asm.abs_l("rt_list_write_slot"))
              asm.rts
            end

            # rt_list_fill(list, from, count, value): count items from +from+ set to the value. A count
            # of nought or less sets none; an index outside the list, first or last, stops the game
            # before anything is written.
            def emit_fill(asm)
              asm.label("rt_list_fill")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(3), asm.d(5))
              asm.tst(:l, asm.d(2))
              asm.branch(:le, "rt_list_fill_done")
              asm.move(:l, asm.d(1), asm.d(6)) # the next item
              asm.move(:l, asm.d(2), asm.d(7)) # how many are left
              asm.jsr(asm.abs_l("rt_list_slot_of_index")) # the first, checked
              asm.move(:l, asm.d(6), asm.d(1))
              asm.add(:l, asm.d(7), asm.d(1))
              asm.subq(:l, 1, asm.d(1))
              asm.jsr(asm.abs_l("rt_list_slot_of_index")) # and the last
              asm.label("rt_list_fill_item")
              asm.move(:l, asm.d(6), asm.d(1))
              asm.jsr(asm.abs_l("rt_list_slot_of_index"))
              asm.jsr(asm.abs_l("rt_list_write_slot"))
              asm.addq(:l, 1, asm.d(6))
              asm.subq(:l, 1, asm.d(7))
              asm.branch(:ne, "rt_list_fill_item")
              asm.label("rt_list_fill_done")
              asm.rts
            end

            # rt_list_copy(list, table, kept, length, at, count): the list made to hold the run of the
            # table's +count+ entries from +at+, held so the run is inside the table (Reference
            # #exec_list_copy). +table+ is the table's address, +kept+ how it keeps an entry (KEPT),
            # +length+ how many entries it has.
            def emit_copy(asm)
              asm.label("rt_list_copy")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.movea(:l, asm.d(1), asm.a(2))
              asm.move(:l, asm.d(3), asm.d(6))
              asm.sub(:l, asm.d(5), asm.d(6)) # the last start that keeps the run inside the table
              asm.branch(:pl, "rt_list_copy_last")
              asm.moveq(0, asm.d(6))
              asm.label("rt_list_copy_last")
              asm.tst(:l, asm.d(4))
              asm.branch(:pl, "rt_list_copy_above")
              asm.moveq(0, asm.d(4))
              asm.label("rt_list_copy_above")
              asm.cmp(:l, asm.d(6), asm.d(4))
              asm.branch(:le, "rt_list_copy_start")
              asm.move(:l, asm.d(6), asm.d(4))
              asm.label("rt_list_copy_start")
              asm.clr(:w, asm.disp(0, FRONT))
              asm.move(:w, asm.d(5), asm.disp(0, LENGTH))
              asm.movea(:l, asm.d(4), asm.a(3)) # where to start in the table
              asm.movea(:l, asm.d(2), asm.a(4)) # how the table keeps its entries
              asm.move(:l, asm.d(5), asm.d(7)) # how many to copy
              asm.moveq(0, asm.d(6)) # the slot to write next
              asm.tst(:l, asm.d(7))
              asm.branch(:le, "rt_list_copy_done")
              asm.label("rt_list_copy_item")
              asm.move(:l, asm.a(3), asm.d(2))
              asm.add(:l, asm.d(6), asm.d(2))
              asm.move(:l, asm.a(4), asm.d(3))
              asm.jsr(asm.abs_l("rt_list_copy_entry"))
              asm.move(:l, asm.d(6), asm.d(2))
              asm.jsr(asm.abs_l("rt_list_slot_of_offset"))
              asm.jsr(asm.abs_l("rt_list_write_slot"))
              asm.addq(:l, 1, asm.d(6))
              asm.cmp(:l, asm.d(7), asm.d(6))
              asm.branch(:ne, "rt_list_copy_item")
              asm.label("rt_list_copy_done")
              asm.rts

              # rt_list_copy_entry: D5 = entry D2 of the table at A2, widened by how it is kept (D3).
              emit_copy_entry(asm)
            end

            def emit_copy_entry(asm)
              asm.label("rt_list_copy_entry")
              asm.moveq(0, asm.d(5))
              asm.cmp(:w, asm.imm(KEPT[:signed_half]), asm.d(3))
              asm.branch(:cs, "rt_list_copy_entry_byte")
              asm.cmp(:w, asm.imm(KEPT[:word]), asm.d(3))
              asm.branch(:eq, "rt_list_copy_entry_word")
              asm.lsl(:l, 1, asm.d(2))
              asm.move(:w, asm.idx(2, 0, 2), asm.d(5))
              asm.cmp(:w, asm.imm(KEPT[:half]), asm.d(3))
              asm.branch(:eq, "rt_list_copy_entry_done")
              asm.ext(:l, asm.d(5))
              asm.rts
              asm.label("rt_list_copy_entry_word")
              asm.lsl(:l, 2, asm.d(2))
              asm.move(:l, asm.idx(2, 0, 2), asm.d(5))
              asm.rts
              asm.label("rt_list_copy_entry_byte")
              asm.move(:b, asm.idx(2, 0, 2), asm.d(5))
              asm.cmp(:w, asm.imm(KEPT[:byte]), asm.d(3))
              asm.branch(:eq, "rt_list_copy_entry_unsigned")
              asm.ext(:w, asm.d(5))
              asm.ext(:l, asm.d(5))
              asm.rts
              asm.label("rt_list_copy_entry_unsigned")
              asm.and(:l, asm.imm(0xFF), asm.d(5))
              asm.label("rt_list_copy_entry_done")
              asm.rts
            end

            # THE SLOTS (all reached with JSR):
            #
            #   rt_list_slot_of_index   A1 = the slot the index in D1 names; an index outside the list
            #                           stops the game
            #   rt_list_slot_of_offset  A1 = the slot D2 places after the first item, unchecked
            #   rt_list_read_slot       D0 = what the slot at A1 holds, widened by its sign
            #   rt_list_write_slot      D5 into the slot at A1, as many bytes as it takes
            def emit_slot_access(asm)
              asm.label("rt_list_slot_of_index")
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.disp(0, LENGTH), asm.d(3))
              asm.cmp(:l, asm.d(3), asm.d(1))
              asm.branch(:cs, "rt_list_slot_inside")
              asm.jmp(asm.abs_l("rt_list_index_fault"))
              asm.label("rt_list_slot_inside")
              asm.move(:l, asm.d(1), asm.d(2))

              asm.label("rt_list_slot_of_offset")
              asm.move(:w, asm.disp(0, FRONT), asm.d(3))
              asm.add(:w, asm.d(2), asm.d(3))
              asm.cmp(:w, asm.disp(0, CAPACITY), asm.d(3))
              asm.branch(:cs, "rt_list_slot_within")
              asm.sub(:w, asm.disp(0, CAPACITY), asm.d(3)) # once round the ring
              asm.label("rt_list_slot_within")
              asm.and(:l, asm.imm(0xFFFF), asm.d(3))
              asm.move(:w, asm.disp(0, SHIFT), asm.d(4))
              asm.lsl(:l, asm.d(4), asm.d(3))
              asm.lea(asm.idx(0, HEADER, 3), asm.a(1))
              asm.rts

              asm.label("rt_list_read_slot")
              asm.move(:w, asm.disp(0, SHIFT), asm.d(4))
              asm.branch(:eq, "rt_list_read_byte")
              asm.subq(:w, 1, asm.d(4))
              asm.branch(:eq, "rt_list_read_half")
              asm.move(:l, asm.ind(1), asm.d(0))
              asm.rts
              asm.label("rt_list_read_half")
              asm.move(:w, asm.ind(1), asm.d(0))
              asm.ext(:l, asm.d(0))
              asm.rts
              asm.label("rt_list_read_byte")
              asm.move(:b, asm.ind(1), asm.d(0))
              asm.ext(:w, asm.d(0))
              asm.ext(:l, asm.d(0))
              asm.rts

              asm.label("rt_list_write_slot")
              asm.move(:w, asm.disp(0, SHIFT), asm.d(4))
              asm.branch(:eq, "rt_list_write_byte")
              asm.subq(:w, 1, asm.d(4))
              asm.branch(:eq, "rt_list_write_half")
              asm.move(:l, asm.d(5), asm.ind(1))
              asm.rts
              asm.label("rt_list_write_half")
              asm.move(:w, asm.d(5), asm.ind(1))
              asm.rts
              asm.label("rt_list_write_byte")
              asm.move(:b, asm.d(5), asm.ind(1))
              asm.rts
            end

            # The game stopped: what went wrong, the list's address, and the numbers that say how,
            # into FAULT for the reader (Frame), then rt_fault (D0 = what went wrong).
            def emit_faults(asm, memory)
              at = ->(plus) { asm.abs_l(memory[Frame::FAULT], plus) }
              asm.label("rt_list_full")
              asm.move(:l, asm.d(0), at.call(Frame::FAULT_LIST))
              asm.moveq(0, asm.d(1))
              asm.move(:w, asm.disp(0, CAPACITY), asm.d(1))
              asm.move(:l, asm.d(1), at.call(Frame::FAULT_FIRST))
              asm.moveq(Frame::LIST_FULL, asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))

              asm.label("rt_list_empty_fault")
              asm.move(:l, asm.d(0), at.call(Frame::FAULT_LIST))
              asm.move(:l, asm.d(1), at.call(Frame::FAULT_FIRST)) # 1 taken from the front, 0 from the back
              asm.moveq(Frame::LIST_EMPTY, asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))

              asm.label("rt_list_index_fault")
              asm.move(:l, asm.d(0), at.call(Frame::FAULT_LIST))
              asm.move(:l, asm.d(1), at.call(Frame::FAULT_FIRST))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, LENGTH), asm.d(2))
              asm.move(:l, asm.d(2), at.call(Frame::FAULT_SECOND))
              asm.moveq(Frame::INDEX_OUT_OF_RANGE, asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))
            end
          end
        end
      end
    end
  end
end
