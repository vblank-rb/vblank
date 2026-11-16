# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # SAVE MEMORY: 32K of RAM on the cartridge that a battery keeps while the console is off,
          # which is what a game saves in. The interpreter's save memory is the Advance's
          # battery-backed one, also 32K and also written a byte at a time (IR::SaveLayout), so the
          # same bytes land in the same places on both, and a save made by one starts the other.
          #
          # On a plain LoROM cartridge the console sees that RAM at $70:0000-$70:7FFF, all of it in
          # one bank, so a place in save memory is simply how far into bank $70 it is. Nothing has to
          # be switched on first or banked in, as on the Game Boy Color: the cartridge answers there
          # from power-on. Every routine reads it through a pointer on the direct page that holds
          # $70:0000, with the place in Y — the long indirect address [pointer],Y.
          #
          # ON A SUPER FX CARTRIDGE bank $70 is the chip's working RAM, and the save is the whole of a
          # second bank, $71, 64K of it (Cartridge::SNESROM::SUPER_FX says why), so the pointer holds
          # $71:0000 there. The save layout is the same packed one (IR::SaveLayout::Memory), so its
          # first 32K holds what a plain cartridge's does, byte for byte, and a game whose saves need
          # more than 32K has the rest. The bank is 64K whole, so Y reaches all of it from the one
          # pointer; the routines differ only where a place or a length can be 64K itself, which
          # does not fit a 16-bit register (#emit_point_or_stop, #emit_sum).
          #
          # WHY A PLAIN CARTRIDGE STAYS AT 32K. bsnes takes a LoROM header asking for more (up to
          # 256K) and shows it 32K a bank, $70:0000-7FFF, $71:0000-7FFF and on, so a save past 32K
          # would cross a bank in the middle of a record, and every routine here would have to step
          # the pointer's bank as it goes (measured in bsnes: $71:0000 is the RAM's byte $8000).
          # 32K is the most one bank holds on that board. A game that needs more is refused by the
          # build in plain words, naming the bytes it needs and the Super FX, whose 64K is one bank
          # (Builder::SaveRecords#refuse_records_over_biggest_memory!).
          #
          # The console's processor must not
          # touch the chip's RAM while the chip runs (Chip), and these routines never do: they are
          # called only from the game's own code, which waits in Chip's rt_chip_run until the chip
          # has stopped, and the vertical blank's interrupt, which does go on meanwhile, never saves.
          #
          # rt_save_read(at, width) and rt_save_write(at, value, width) take one, two or four bytes,
          # lowest first; rt_save_sum(at, length) is SaveLayout.checksum's two 16-bit sums;
          # rt_save_erase does nothing, battery-backed RAM needing no wiping before it is written. A
          # place outside the save stops the game in the interpreter's words (Faults.save_outside).
          module Saving
            # A plain cartridge's save, the size a game that saves has there
            # (Console::SNES_PLAIN_SAVE_MEMORIES).
            SIZE = 0x8000

            # The most a save can be: one whole bank, all of it reached through Y.
            BANK_BYTES = 0x10000

            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)

            # The direct page the routines work on: the pointer to save memory (three bytes and a
            # spare), and the fault's code while it is being said.
            Scratch = Data.define(:pointer, :fault)

            module_function

            def scratch(memory) = Scratch.new(pointer: memory.scratch(4), fault: memory.scratch(2))

            # +bank+ is the bank the console sees the save in (Cartridge::SNESROM::Board#save_bank),
            # and +size+ how many bytes the save is (IR::SaveLayout.memory_of), at most a bank.
            def emit(asm, memory, s, bank:, size: SIZE)
              raise ArgumentError, "a save of #{size} bytes is more than one bank" if size > BANK_BYTES

              emit_read(asm, s)
              emit_write(asm, s)
              emit_sum(asm, s, whole_bank: size == BANK_BYTES)
              asm.label("rt_save_erase")
              asm.rtl
              emit_point_or_stop(asm, memory, s, bank, size)
            end

            # rt_save_read: R0 = the +width+ (R1) bytes at +at+ (R0), lowest first, the rest nought.
            def emit_read(asm, s)
              asm.label("rt_save_read")
              asm.lda(Frame::SAVE_READ_OUTSIDE)
              asm.ldx(R1)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.stz(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_save_read_byte")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct_x(R0))
              asm.iny
              asm.inx
              asm.cpx(asm.direct(R1))
              asm.bne("rt_save_read_byte")
              asm.rep(0x20)
              asm.rtl
            end

            # rt_save_write: the low +width+ (R2) bytes of +value+ (R1) at +at+ (R0), lowest first.
            def emit_write(asm, s)
              asm.label("rt_save_write")
              asm.lda(Frame::SAVE_WRITE_OUTSIDE)
              asm.ldx(R2)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_save_write_byte")
              asm.lda(asm.direct_x(R1))
              asm.sta(asm.ind_long_y(s.pointer))
              asm.iny
              asm.inx
              asm.cpx(asm.direct(R2))
              asm.bne("rt_save_write_byte")
              asm.rep(0x20)
              asm.rtl
            end

            # rt_save_sum: R0 = SaveLayout.checksum of the +length+ (R1) bytes at +at+ (R0): a running
            # total of the bytes and a running total of those totals, each kept to 16 bits, the second
            # in R0's high half. A length below nought sums no bytes, as the interpreter's empty range.
            #
            # On a save of a +whole_bank+ the length can be the whole 64K, whose low half is nought:
            # then its high half says it is not empty, and is counted into the pointer's bank.
            def emit_sum(asm, s, whole_bank: false)
              asm.label("rt_save_sum")
              asm.lda(Frame::SAVE_READ_OUTSIDE)
              asm.ldx(R1)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.stz(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.lda(asm.direct(R1 + 2))
              asm.bmi("rt_save_sum_done")
              # Inside the save, so the length's low half is all of it, but for a whole bank's.
              # Y counts up from minus the length to nought, and the pointer is moved back by as
              # much, so one increase of Y both steps to the next byte and says when the last is
              # summed: the pointer, $bank:0000, becomes the place past the last byte less 64K,
              # which Y's 64K less the length brings back to the first. The loop sums two bytes a
              # time round, and an odd length starts at its second.
              asm.lda(asm.direct(R1))
              asm.ora(asm.direct(R1 + 2)) if whole_bank
              asm.beq("rt_save_sum_done")
              asm.tya
              asm.clc
              asm.adc(asm.direct(R1))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.direct(s.pointer + 2))
              asm.adc(0xFFFF)
              if whole_bank
                asm.clc
                asm.adc(asm.direct(R1 + 2))
              end
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(0)
              asm.sec
              asm.sbc(asm.direct(R1))
              asm.tay
              asm.lda(asm.direct(R1))
              asm.lsr
              asm.bcs("rt_save_sum_second")
              asm.label("rt_save_sum_byte")
              emit_sum_byte(asm, s)
              asm.label("rt_save_sum_second")
              emit_sum_byte(asm, s)
              asm.bne("rt_save_sum_byte")
              asm.label("rt_save_sum_done")
              asm.rtl
            end

            # The byte Y names into both totals, and Y on to the next; Z is set past the last.
            def emit_sum_byte(asm, s)
              asm.lda(asm.ind_long_y(s.pointer))
              asm.and_a(0x00FF)
              asm.clc
              asm.adc(asm.direct(R0))
              asm.sta(asm.direct(R0))
              asm.clc
              asm.adc(asm.direct(R0 + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.iny
            end

            # A WHOLE LIST MOVED BETWEEN SAVE MEMORY AND WORK RAM AS A BLOCK (IR save_load_list,
            # save_store_list; Reference#exec_save_load_list, #exec_save_store_list). A record that
            # keeps a list used to read and write it an item at a time, each a call that checked the
            # place again and found the item's slot again. A slot keeps its bytes lowest first, as
            # save memory does, so the items are the same bytes in both places and the move is a
            # copy: the place checked once, and a byte read through one pointer and written through
            # the other.
            #
            # rt_save_load_list(list, at, count): the list made to hold +count+ items, which the
            # lowering has held to nought and what the list can hold, read from +at+ on. It holds
            # them from its first slot, so the bytes go in one run.
            #
            # rt_save_store_list(list, at): every item written from +at+ on, oldest first. The list
            # is a ring, so its oldest item can be in any slot: the copy starts there and comes
            # round to the first slot where the slots end. The bytes are written in rising order, as
            # the writes one at a time were, so a power cut leaves what it left then.
            #
            # A run of the list's slots is one stretch of work RAM, so each run is copied by a loop of
            # one read and one write a byte, Y indexing both sides: a second pointer (+lists.table+)
            # is set to the list's slot less the place in save memory, so the same Y that walks save
            # memory walks the slots. A store comes round the ring in at most two runs.
            #
            # +lists+ is Lists' own scratch: the list's pointer, how far into the list the copy is
            # (slot), how far into save memory (count), and the second pointer (table), which holds
            # where the slots end until the runs are known.
            def emit_list_moves(asm, s, lists)
              list = lists.list

              asm.label("rt_save_load_list")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.lda(0)
              asm.ldy(Lists::FRONT)
              asm.sta(asm.ind_long_y(list))
              asm.lda(asm.direct(R2))
              asm.ldy(Lists::LENGTH)
              asm.sta(asm.ind_long_y(list))
              emit_count_in_bytes(asm, list, R2, "rt_save_load_list")
              emit_place_into_r0(asm)
              asm.lda(Frame::SAVE_READ_OUTSIDE)
              asm.ldx(R2)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.sty(asm.direct(lists.count))
              asm.lda(Lists::HEADER)
              asm.sta(asm.direct(lists.slot))
              asm.ldx(asm.direct(R2))
              asm.beq("rt_save_load_list_done")
              emit_run_pointer(asm, lists)
              asm.sep(0x20)
              asm.label("rt_save_load_list_byte")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.ind_long_y(lists.table))
              asm.iny
              asm.dex
              asm.bne("rt_save_load_list_byte")
              asm.rep(0x20)
              asm.label("rt_save_load_list_done")
              asm.rtl

              asm.label("rt_save_store_list")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.ldy(Lists::LENGTH)
              asm.lda(asm.ind_long_y(list))
              asm.sta(asm.direct(R2))
              asm.stz(asm.direct(R2 + 2))
              emit_count_in_bytes(asm, list, R2, "rt_save_store_list")
              # Where the slots end, and then where the oldest item is (both leave it in the slot).
              asm.ldy(Lists::CAPACITY)
              asm.lda(asm.ind_long_y(list))
              asm.jsr(asm.abs("rt_list_slot_at"))
              asm.lda(asm.direct(lists.slot))
              asm.sta(asm.direct(lists.table))
              asm.lda(0)
              asm.jsr(asm.abs("rt_list_slot_of_a"))
              emit_place_into_r0(asm)
              asm.lda(Frame::SAVE_WRITE_OUTSIDE)
              asm.ldx(R2)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.sty(asm.direct(lists.count))
              asm.lda(asm.direct(R2))
              asm.beq("rt_save_store_list_done")
              # The first run: from the oldest item to the last slot, or fewer where the list ends
              # first. Then what is left, from the first slot.
              asm.sec
              asm.lda(asm.direct(lists.table))
              asm.sbc(asm.direct(lists.slot))
              asm.cmp(asm.direct(R2))
              asm.bcc("rt_save_store_list_to_end")
              asm.lda(asm.direct(R2))
              asm.label("rt_save_store_list_to_end")
              asm.jsr(asm.abs("rt_save_store_run"))
              asm.lda(asm.direct(R2))
              asm.beq("rt_save_store_list_done")
              asm.ldx(Lists::HEADER)
              asm.stx(asm.direct(lists.slot))
              asm.jsr(asm.abs("rt_save_store_run"))
              asm.label("rt_save_store_list_done")
              asm.rtl

              # rt_save_store_run (JSR): A bytes (more than nought) from the slot to the place in
              # save memory, both moved on past them, and R2 less them.
              asm.label("rt_save_store_run")
              asm.tax
              asm.eor(0xFFFF)
              asm.sec
              asm.adc(asm.direct(R2))
              asm.sta(asm.direct(R2))
              emit_run_pointer(asm, lists)
              asm.sep(0x20)
              asm.label("rt_save_store_list_byte")
              asm.lda(asm.ind_long_y(lists.table))
              asm.sta(asm.ind_long_y(s.pointer))
              asm.iny
              asm.dex
              asm.bne("rt_save_store_list_byte")
              asm.rep(0x20)
              asm.sty(asm.direct(lists.count))
              asm.rts
            end

            # The second pointer, the list's place and slot less the place in save memory, into
            # +lists.table+, and Y the place in save memory.
            def emit_run_pointer(asm, lists)
              asm.lda(asm.direct(lists.list))
              asm.clc
              asm.adc(asm.direct(lists.slot))
              asm.sta(asm.direct(lists.table))
              asm.lda(asm.direct(lists.list + 2))
              asm.adc(0)
              asm.sta(asm.direct(lists.table + 2))
              asm.lda(asm.direct(lists.table))
              asm.sec
              asm.sbc(asm.direct(lists.count))
              asm.sta(asm.direct(lists.table))
              asm.lda(asm.direct(lists.table + 2))
              asm.sbc(0)
              asm.sta(asm.direct(lists.table + 2))
              asm.ldy(asm.direct(lists.count))
            end

            # The count in working number +count+ made a count of bytes: doubled once for a list of
            # halves and twice for one of words. +named+ keeps the labels apart.
            def emit_count_in_bytes(asm, list, count, named)
              asm.ldy(Lists::WIDTH)
              asm.lda(asm.ind_long_y(list))
              asm.cmp(2)
              asm.bcc("#{named}_in_bytes")
              asm.asl(asm.direct(count))
              asm.cmp(4)
              asm.bcc("#{named}_in_bytes")
              asm.asl(asm.direct(count))
              asm.label("#{named}_in_bytes")
            end

            # The place in save memory, the routine's second number, into R0, where
            # rt_save_point_or_stop looks for it; the list's own place is in its pointer by now.
            def emit_place_into_r0(asm)
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(R0))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.direct(R0 + 2))
            end

            # rt_save_point_or_stop (JSR): +at+ in R0 and a count of bytes in the working number X
            # names, both 32 bits; A the fault to stop with when they do not fit. They fit, as
            # SaveImage has it, when +at+ is nought or more and +at+ + count is no more than the
            # save's +size+. Then the pointer holds the save's start, +bank+:0000, and Y is +at+.
            # Otherwise the game stops, the place and the size as the fault's two numbers. A count
            # below nought (only a sum's length can be) fits wherever it ends up no further than the
            # save's end, even from a place far past it, and reads no bytes, so Y need not hold all
            # of such a place. A save of a whole bank ends at $1:0000, whose high half is 1.
            def emit_point_or_stop(asm, memory, s, bank, size)
              asm.label("rt_save_point_or_stop")
              asm.sta(asm.direct(s.fault))
              asm.lda(asm.direct(R0 + 2))
              asm.bmi("rt_save_outside") # below nought: never inside
              asm.lda(asm.direct(R0))
              asm.clc
              asm.adc(asm.direct_x(0))
              asm.tay # the end's low half, kept while its high half is worked out
              asm.lda(asm.direct(R0 + 2))
              asm.adc(asm.direct_x(2))
              asm.bvs("rt_save_outside") # a count so big the end came round past the top
              asm.bmi("rt_save_inside") # a count below nought ends before the place: no bytes
              if size == BANK_BYTES
                asm.beq("rt_save_inside") # ends inside the bank
                asm.cmp(1)
                asm.bne("rt_save_outside")
                asm.cpy(0)
                asm.bne("rt_save_outside") # past the bank's end
              else
                asm.bne("rt_save_outside")
                asm.cpy(size + 1)
                asm.bcs("rt_save_outside")
              end
              asm.label("rt_save_inside")
              asm.stz(asm.direct(s.pointer))
              asm.lda(bank)
              asm.sta(asm.direct(s.pointer + 2))
              asm.ldy(asm.direct(R0))
              asm.rts
              asm.label("rt_save_outside")
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST))
              asm.lda(asm.direct(R0 + 2))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST + 2))
              asm.lda(size & 0xFFFF)
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND))
              if (size >> 16).zero?
                asm.stz(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND + 2))
              else
                asm.lda(size >> 16)
                asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND + 2))
              end
              asm.lda(asm.direct(s.fault))
              asm.jml(asm.long("rt_fault"))
            end
          end
        end
      end
    end
  end
end
