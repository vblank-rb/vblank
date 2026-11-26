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

            def emit(asm, memory)
              emit_read(asm)
              emit_write(asm)
              emit_sum(asm)
              asm.label("rt_save_erase")
              asm.rts
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
