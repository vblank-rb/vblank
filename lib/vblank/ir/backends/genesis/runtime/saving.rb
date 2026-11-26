# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # Save memory: 32K of RAM on the cartridge that a battery keeps while the console is off, which is what
          # a game saves in. The interpreter's save memory is the Advance's battery-backed one, also 32K and also
          # written a byte at a time (IR::SaveLayout), so the same bytes land in the same places on both, and a
          # save made by one starts the other.
          #
          # The cartridge's header names the RAM (Cartridge::GenesisROM), which the console sees after the first 2
          # MB of the cartridge's address space, from $200000, with a byte on every second address: the odd ones
          # (plutiedev, "Saving with SRAM"; Genesis Plus GX, core/cart_hw/sram.c). So byte k of the save is at
          # $200001 + 2k. A cartridge of 2 MB or less needs no switch to see it.
          #
          # rt_save_read(at, width) and rt_save_write(at, value, width) take one, two or four bytes, lowest first,
          # and a place outside the save stops the game in the interpreter's words (Faults.save_outside). They
          # keep to the 68000's rules for the runtime: numbers in D0, D1 and D2, the answer in D0, A5 untouched.
          module Saving
            # The save, the size a game that saves has (Console::GENESIS_SAVE_MEMORIES).
            SIZE = 0x8000

            module_function

            # +list_moves+ for a game that moves a whole list to or from save memory (#emit_list_moves).
            def emit(asm, memory, list_moves: false)
              emit_read(asm)
              emit_write(asm)
              emit_sum(asm)
              asm.label("rt_save_erase")
              asm.rts
              emit_list_moves(asm) if list_moves
              emit_point_or_stop(asm, memory)
            end

            # rt_save_read: D0 = the +width+ (D1) bytes at +at+ (D0), lowest first, the rest nought. The bytes are
            # taken from the last, so each goes in under the ones that came after it.
            def emit_read(asm)
              asm.label("rt_save_read")
              asm.move(:l, asm.d(1), asm.d(3))
              asm.moveq(Frame::SAVE_READ_OUTSIDE, asm.d(4))
              asm.jsr(asm.abs_l("rt_save_point_or_stop"))
              asm.lea(asm.abs_l(Console::GenesisHardware::SAVE_RAM_FIRST), asm.a(0))
              asm.add(:l, asm.d(1), asm.d(0))
              asm.add(:l, asm.d(0), asm.d(0)) # two bytes of the address space for each of the save's
              asm.add(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(0))
              asm.subq(:w, 1, asm.d(1))
              asm.label("rt_save_read_byte")
              asm.subq(:l, 2, asm.a(0))
              asm.lsl(:l, 8, asm.d(0))
              asm.move(:b, asm.ind(0), asm.d(0))
              asm.dbra(asm.d(1), "rt_save_read_byte")
              asm.rts
            end

            # rt_save_write: the low +width+ (D2) bytes of +value+ (D1) at +at+ (D0), lowest first, in rising
            # places.
            def emit_write(asm)
              asm.label("rt_save_write")
              asm.move(:l, asm.d(2), asm.d(3))
              asm.moveq(Frame::SAVE_WRITE_OUTSIDE, asm.d(4))
              asm.jsr(asm.abs_l("rt_save_point_or_stop"))
              asm.lea(asm.abs_l(Console::GenesisHardware::SAVE_RAM_FIRST), asm.a(0))
              asm.add(:l, asm.d(0), asm.d(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.subq(:w, 1, asm.d(2))
              asm.label("rt_save_write_byte")
              asm.move(:b, asm.d(1), asm.ind(0))
              asm.addq(:l, 2, asm.a(0))
              asm.lsr(:l, 8, asm.d(1))
              asm.dbra(asm.d(2), "rt_save_write_byte")
              asm.rts
            end

            # rt_save_sum: D0 = SaveLayout.checksum of the +length+ (D1) bytes at +at+ (D0): a running total of the
            # bytes and a running total of those totals, each kept to 16 bits, the second in D0's high half. The
            # place is checked as the interpreter checks it (SaveImage#refuse_outside_memory!): below nought, or
            # its end (the place and the length, which can be below nought) past the save, stops the game. A
            # length of nought or less then sums no bytes.
            def emit_sum(asm)
              asm.label("rt_save_sum")
              asm.tst(:l, asm.d(0))
              asm.branch(:mi, "rt_save_sum_outside")
              asm.move(:l, asm.d(0), asm.d(5))
              asm.add(:l, asm.d(1), asm.d(5))
              asm.branch(:vs, "rt_save_sum_outside") # an end past the largest number is past the save too
              asm.cmp(:l, asm.imm(SIZE), asm.d(5))
              asm.branch(:gt, "rt_save_sum_outside")
              asm.tst(:l, asm.d(1))
              asm.branch(:le, "rt_save_sum_none")
              asm.lea(asm.abs_l(Console::GenesisHardware::SAVE_RAM_FIRST), asm.a(0))
              asm.add(:l, asm.d(0), asm.d(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(2))
              asm.moveq(0, asm.d(3)) # the total of the bytes
              asm.moveq(0, asm.d(5)) # the total of those totals
              asm.subq(:w, 1, asm.d(1))
              asm.label("rt_save_sum_byte")
              asm.move(:b, asm.ind(0), asm.d(2))
              asm.add(:w, asm.d(2), asm.d(3))
              asm.add(:w, asm.d(3), asm.d(5))
              asm.addq(:l, 2, asm.a(0))
              asm.dbra(asm.d(1), "rt_save_sum_byte")
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.d(5), asm.d(0))
              asm.swap(asm.d(0))
              asm.move(:w, asm.d(3), asm.d(0))
              asm.rts
              asm.label("rt_save_sum_none")
              asm.moveq(0, asm.d(0))
              asm.rts
              asm.label("rt_save_sum_outside")
              asm.moveq(Frame::SAVE_READ_OUTSIDE, asm.d(4))
              asm.bra("rt_save_outside")
            end

            # A whole list moved between save memory and work RAM as a block (IR save_load_list, save_store_list;
            # Reference#exec_save_load_list, #exec_save_store_list). The place is checked once, not for each item.
            #
            # A slot keeps a number highest byte first, as the 68000 does, and save memory keeps it lowest byte
            # first, so each item goes over its bytes in reverse: save byte k of an item of w bytes is slot byte
            # w - 1 - k. A slot is walked from its end towards its start while the save's places rise, one byte at
            # every second address, so a power cut leaves what it left when the items were moved one at a time.
            #
            # rt_save_load_list(list, at, count): the list made to hold +count+ items (D2, held by the lowering to
            # nought and what the list can hold), the first at its first slot, read from +at+ on.
            #
            # rt_save_store_list(list, at): every item written from +at+ on, oldest first. The list is a ring, so
            # its oldest item can be in any slot: the copy starts there and comes round to the first slot where the
            # slots end, in at most two runs.
            def emit_list_moves(asm)
              emit_load_list(asm)
              emit_store_list(asm)
              emit_move_items(asm, "rt_save_load_list_items", load: true)
              emit_move_items(asm, "rt_save_store_list_items", load: false)
            end

            def emit_load_list(asm)
              asm.label("rt_save_load_list")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.clr(:w, asm.disp(0, Lists::FRONT))
              asm.move(:w, asm.d(2), asm.disp(0, Lists::LENGTH))
              asm.move(:l, asm.d(1), asm.d(7))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.disp(0, Lists::SHIFT), asm.d(6))
              asm.move(:l, asm.d(2), asm.d(3))
              asm.lsl(:l, asm.d(6), asm.d(3)) # how many bytes
              asm.move(:l, asm.d(7), asm.d(0))
              asm.moveq(Frame::SAVE_READ_OUTSIDE, asm.d(4))
              asm.jsr(asm.abs_l("rt_save_point_or_stop"))
              asm.tst(:l, asm.d(2))
              asm.branch(:eq, "rt_save_load_list_done")
              asm.lea(asm.abs_l(Console::GenesisHardware::SAVE_RAM_FIRST), asm.a(1))
              asm.add(:l, asm.d(7), asm.d(7))
              asm.add(:l, asm.d(7), asm.a(1))
              asm.lea(asm.disp(0, Lists::HEADER), asm.a(2))
              asm.move(:l, asm.d(2), asm.d(1))
              asm.jsr(asm.abs_l("rt_save_load_list_items"))
              asm.label("rt_save_load_list_done")
              asm.rts
            end

            def emit_store_list(asm)
              asm.label("rt_save_store_list")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(1), asm.d(7))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, Lists::LENGTH), asm.d(2))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.disp(0, Lists::SHIFT), asm.d(6))
              asm.move(:l, asm.d(2), asm.d(3))
              asm.lsl(:l, asm.d(6), asm.d(3)) # how many bytes
              asm.move(:l, asm.d(7), asm.d(0))
              asm.moveq(Frame::SAVE_WRITE_OUTSIDE, asm.d(4))
              asm.jsr(asm.abs_l("rt_save_point_or_stop"))
              asm.tst(:l, asm.d(2))
              asm.branch(:eq, "rt_save_store_list_done")
              asm.lea(asm.abs_l(Console::GenesisHardware::SAVE_RAM_FIRST), asm.a(1))
              asm.add(:l, asm.d(7), asm.d(7))
              asm.add(:l, asm.d(7), asm.a(1))
              # The first run: from the oldest item to the last slot, or the last item if that comes first.
              asm.moveq(0, asm.d(4))
              asm.move(:w, asm.disp(0, Lists::FRONT), asm.d(4))
              asm.moveq(0, asm.d(5))
              asm.move(:w, asm.disp(0, Lists::CAPACITY), asm.d(5))
              asm.sub(:l, asm.d(4), asm.d(5)) # the slots from the oldest to the end
              asm.move(:l, asm.d(2), asm.d(1))
              asm.cmp(:l, asm.d(5), asm.d(1))
              asm.branch(:ls, "rt_save_store_list_first")
              asm.move(:l, asm.d(5), asm.d(1))
              asm.label("rt_save_store_list_first")
              asm.sub(:l, asm.d(1), asm.d(2)) # what is left for the second run
              asm.lsl(:l, asm.d(6), asm.d(4))
              asm.lea(asm.disp(0, Lists::HEADER), asm.a(2))
              asm.add(:l, asm.d(4), asm.a(2))
              asm.jsr(asm.abs_l("rt_save_store_list_items"))
              # The second run: what is left, from the first slot.
              asm.move(:l, asm.d(2), asm.d(1))
              asm.branch(:eq, "rt_save_store_list_done")
              asm.lea(asm.disp(0, Lists::HEADER), asm.a(2))
              asm.jsr(asm.abs_l("rt_save_store_list_items"))
              asm.label("rt_save_store_list_done")
              asm.rts
            end

            # rt_save_load_list_items, rt_save_store_list_items: D1 items (not nought) between A2, the first slot of the
            # run, and A1, the save's place of the first, both moved on past what is copied. D6 is the list's shift.
            # D3 to D5 are used; D2 and D6 are kept.
            def emit_move_items(asm, label, load:)
              asm.label(label)
              asm.moveq(1, asm.d(3))
              asm.lsl(:l, asm.d(6), asm.d(3)) # the bytes of an item
              asm.move(:l, asm.d(3), asm.d(5))
              asm.add(:l, asm.d(5), asm.d(5)) # and two items' bytes: from the end of one to the end of the next
              asm.add(:l, asm.d(3), asm.a(2)) # the end of the first item
              asm.subq(:w, 1, asm.d(3))
              asm.subq(:w, 1, asm.d(1))
              asm.label("#{label}_item")
              asm.move(:w, asm.d(3), asm.d(4))
              asm.label("#{label}_byte")
              if load
                asm.move(:b, asm.ind(1), asm.pre(2))
              else
                asm.move(:b, asm.pre(2), asm.ind(1))
              end
              asm.addq(:l, 2, asm.a(1))
              asm.dbra(asm.d(4), "#{label}_byte")
              asm.add(:l, asm.d(5), asm.a(2))
              asm.dbra(asm.d(1), "#{label}_item")
              asm.rts
            end

            # rt_save_point_or_stop: D0 = a place, D3 = how many bytes from it, D4 = the fault's number. The
            # place is outside the save when it is past its end, or the bytes are, taken as unsigned numbers so a
            # place below nought is outside too. The game then stops, the place and the save's size kept for
            # the reader (Frame's FAULT), D0 = the fault's number.
            def emit_point_or_stop(asm, memory)
              at = ->(plus) { asm.abs_l(memory[Frame::FAULT], plus) }
              asm.label("rt_save_point_or_stop")
              asm.cmp(:l, asm.imm(SIZE), asm.d(0))
              asm.branch(:hi, "rt_save_outside")
              asm.move(:l, asm.d(0), asm.d(5))
              asm.add(:l, asm.d(3), asm.d(5))
              asm.cmp(:l, asm.imm(SIZE), asm.d(5))
              asm.branch(:hi, "rt_save_outside")
              asm.rts
              asm.label("rt_save_outside")
              asm.move(:l, asm.d(0), at.call(Frame::FAULT_FIRST))
              asm.move(:l, asm.imm(SIZE), at.call(Frame::FAULT_SECOND))
              asm.move(:l, asm.d(4), asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))
            end
          end
        end
      end
    end
  end
end
