# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # THE LISTS: a game's `list`, and every field of a pool, as the interpreter keeps them
          # (Reference::ListValue): items added at the back and taken from either end, read and written by
          # index, and the game stopped, in the interpreter's words, by an index outside the list, an item
          # added to a full one or taken from an empty one.
          #
          # A list lives in the data segment: a header of four 16-bit words (how many it can hold, which slot
          # its first item is in, how many it holds, and how far to shift a slot's number to get its place in
          # bytes: 0, 1 or 2 for slots of 1, 2 or 4 bytes) and then its slots. The items go round the slots
          # like a ring, so taking one from the front moves where the first item is, not every item after it.
          # This is the layout every cartridge's reader asks for (CartridgeHeadlessRun#read_lists).
          #
          # A slot narrower than four bytes keeps the low bits of what goes in and reads back with its top
          # bit as the sign: 200 in a byte slot reads -56, as the interpreter has it.
          #
          # Every routine is handed the list's place in BX, and its numbers in EAX, ECX and EDX (rt_list_drop
          # which end in AL; rt_list_sort the other list's place in DI and which way in DL). Each keeps BX, BP
          # and the segment registers and may change the rest.
          module Lists
            CAPACITY = 0
            FRONT = 2
            LENGTH = 4
            SHIFT = 6 # where the header keeps how far a slot's number is shifted
            HEADER = 8 # how long the header is: the slots begin here

            # The most a list can hold: a slot's number and the first item's are added as 16-bit numbers
            # before they are brought round the ring.
            MOST_ITEMS = 0x7FFF

            module_function

            # +sorts+ is whether the game puts a list in order, which is a routine of its own.
            def emit(asm, memory, sorts:)
              emit_slots(asm)
              emit_counts(asm)
              emit_get_and_set(asm)
              emit_push_and_drop(asm)
              emit_fill(asm)
              emit_sort(asm) if sorts
              emit_faults(asm, memory)
            end

            # rt_list_slot: SI at the slot AX places after the list's first item, and CL the list's shift.
            # rt_list_read_slot: EAX from the slot at SI, widened by its sign. rt_list_write_slot: EDX into it.
            # Each of the two takes CL as rt_list_slot left it.
            def emit_slots(asm)
              asm.label("rt_list_slot")
              asm.add(:ax, X86.mem(:bx, FRONT, size: 16))
              asm.cmp(:ax, X86.mem(:bx, CAPACITY, size: 16))
              asm.jb("rt_list_slot_within")
              asm.sub(:ax, X86.mem(:bx, CAPACITY, size: 16)) # once round the ring
              asm.label("rt_list_slot_within")
              asm.mov(:cl, X86.mem(:bx, SHIFT, size: 8))
              asm.shl(:ax, :cl)
              asm.mov(:si, :ax)
              asm.add(:si, :bx)
              asm.add(:si, HEADER)
              asm.ret

              asm.label("rt_list_read_slot")
              asm.cmp(:cl, 1)
              asm.ja("rt_list_read_four")
              asm.je("rt_list_read_two")
              asm.movsx(:eax, X86.mem(:si, 0, size: 8))
              asm.ret
              asm.label("rt_list_read_two")
              asm.movsx(:eax, X86.mem(:si, 0, size: 16))
              asm.ret
              asm.label("rt_list_read_four")
              asm.mov(:eax, X86.mem(:si, 0, size: 32))
              asm.ret

              asm.label("rt_list_write_slot")
              asm.cmp(:cl, 1)
              asm.ja("rt_list_write_four")
              asm.je("rt_list_write_two")
              asm.mov(X86.mem(:si, 0, size: 8), :dl)
              asm.ret
              asm.label("rt_list_write_two")
              asm.mov(X86.mem(:si, 0, size: 16), :dx)
              asm.ret
              asm.label("rt_list_write_four")
              asm.mov(X86.mem(:si, 0, size: 32), :edx)
              asm.ret
            end

            # rt_list_empty: no items. rt_list_at_capacity: as many as it holds, from its first slot
            # (rt_list_fill then sets what they are). rt_list_length: EAX how many it holds.
            def emit_counts(asm)
              asm.label("rt_list_empty")
              asm.mov(X86.mem(:bx, FRONT, size: 16), 0)
              asm.mov(X86.mem(:bx, LENGTH, size: 16), 0)
              asm.ret

              asm.label("rt_list_at_capacity")
              asm.mov(:ax, X86.mem(:bx, CAPACITY, size: 16))
              asm.mov(X86.mem(:bx, FRONT, size: 16), 0)
              asm.mov(X86.mem(:bx, LENGTH, size: 16), :ax)
              asm.ret

              asm.label("rt_list_length")
              asm.xor(:eax, :eax)
              asm.mov(:ax, X86.mem(:bx, LENGTH, size: 16))
              asm.ret
            end

            # ECX the list's length, and the game stopped unless the index in EAX is inside it. Compared as
            # numbers with no sign, so an index below nought is past the end too.
            def emit_index_check(asm)
              asm.xor(:ecx, :ecx)
              asm.mov(:cx, X86.mem(:bx, LENGTH, size: 16))
              asm.cmp(:eax, :ecx)
              asm.jae("rt_list_index_fault")
            end

            # rt_list_get: EAX the item at the index in EAX. rt_list_set: EDX into the item at the index in EAX.
            # An index outside the list stops the game before anything is read or written.
            def emit_get_and_set(asm)
              asm.label("rt_list_get")
              emit_index_check(asm)
              asm.call("rt_list_slot")
              asm.jmp("rt_list_read_slot")

              asm.label("rt_list_set")
              emit_index_check(asm)
              asm.call("rt_list_slot")
              asm.jmp("rt_list_write_slot")
            end

            # rt_list_push: EDX into the slot after the last item. A full list stops the game. rt_list_drop: the
            # first item taken (AL 1) or the last (AL 0). An empty list stops the game.
            def emit_push_and_drop(asm)
              asm.label("rt_list_push")
              asm.mov(:ax, X86.mem(:bx, LENGTH, size: 16))
              asm.cmp(:ax, X86.mem(:bx, CAPACITY, size: 16))
              asm.jae("rt_list_full_fault")
              asm.inc(X86.mem(:bx, LENGTH, size: 16))
              asm.call("rt_list_slot")
              asm.jmp("rt_list_write_slot")

              asm.label("rt_list_drop")
              asm.cmp(X86.mem(:bx, LENGTH, size: 16), 0)
              asm.je("rt_list_empty_fault")
              asm.dec(X86.mem(:bx, LENGTH, size: 16))
              asm.test(:al, :al)
              asm.je("rt_list_dropped")
              asm.mov(:ax, X86.mem(:bx, FRONT, size: 16))
              asm.inc(:ax)
              asm.cmp(:ax, X86.mem(:bx, CAPACITY, size: 16))
              asm.jb("rt_list_front_within")
              asm.xor(:ax, :ax)
              asm.label("rt_list_front_within")
              asm.mov(X86.mem(:bx, FRONT, size: 16), :ax)
              asm.label("rt_list_dropped")
              asm.ret
            end

            # rt_list_fill: ECX items from the index in EAX set to EDX. A count of nought or less sets none; an
            # index outside the list, the first or the last, stops the game before anything is written.
            def emit_fill(asm)
              asm.label("rt_list_fill")
              asm.cmp(:ecx, 0)
              asm.jle("rt_list_filled")
              asm.mov(:edi, :ecx)
              emit_index_check(asm) # ECX is the length from here
              asm.xchg(:eax, :edi) # EAX the count, EDI the first index
              asm.add(:eax, :edi)
              asm.dec(:eax) # the last index
              asm.cmp(:eax, :ecx)
              asm.jae("rt_list_index_fault")
              asm.sub(:ax, :di)
              asm.inc(:ax) # the count again, which fits 16 bits now that the last index is inside the list
              asm.label("rt_list_fill_next")
              asm.push(:ax)
              asm.mov(:ax, :di)
              asm.call("rt_list_slot")
              asm.call("rt_list_write_slot")
              asm.pop(:ax)
              asm.inc(:di)
              asm.dec(:ax)
              asm.jne("rt_list_fill_next")
              asm.label("rt_list_filled")
              asm.ret
            end

            # rt_list_sort (Reference#exec_list_sort): every item of the list put in order by the number the list
            # at DI holds at it, the smallest first, or the biggest when DL is not nought. Every item is
            # checked to be a place in that list before anything moves. An insertion sort: each item in turn
            # moves back past the ones before it whose numbers are strictly beyond its own, so level items
            # keep their order and a list already in order costs a compare an item.
            #
            # What it keeps is on the stack: BP+0 the item being placed and +4 its number, +8 which item that
            # is, +10 where it has moved back to, +12 how many there are, +14 whether the biggest go first.
            def emit_sort(asm)
              kept = ->(offset, size) { X86.mem(:bp, offset, size: size) }
              asm.label("rt_list_sort")
              asm.push(:bp)
              asm.sub(:sp, 16)
              asm.mov(:bp, :sp)
              asm.xor(:dh, :dh)
              asm.mov(kept.call(14, 16), :dx)
              asm.mov(:ax, X86.mem(:bx, LENGTH, size: 16))
              asm.mov(kept.call(12, 16), :ax)
              asm.mov(kept.call(8, 16), 0)
              asm.label("rt_list_sort_check")
              asm.mov(:ax, kept.call(8, 16))
              asm.cmp(:ax, kept.call(12, 16))
              asm.jae("rt_list_sort_checked")
              asm.call("rt_list_slot")
              asm.call("rt_list_read_slot")
              asm.xchg(:bx, :di)
              emit_index_check(asm) # against the list of numbers, which the fault then names
              asm.xchg(:bx, :di)
              asm.inc(kept.call(8, 16))
              asm.jmp("rt_list_sort_check")
              asm.label("rt_list_sort_checked")
              asm.mov(kept.call(8, 16), 1)
              asm.label("rt_list_sort_item")
              asm.mov(:ax, kept.call(8, 16))
              asm.cmp(:ax, kept.call(12, 16))
              asm.jae("rt_list_sort_done")
              asm.mov(kept.call(10, 16), :ax)
              asm.call("rt_list_slot")
              asm.call("rt_list_read_slot")
              asm.mov(kept.call(0, 32), :eax)
              asm.xchg(:bx, :di)
              asm.call("rt_list_slot")
              asm.call("rt_list_read_slot")
              asm.xchg(:bx, :di)
              asm.mov(kept.call(4, 32), :eax)
              asm.label("rt_list_sort_back")
              asm.mov(:ax, kept.call(10, 16))
              asm.test(:ax, :ax)
              asm.je("rt_list_sort_place")
              asm.dec(:ax)
              asm.call("rt_list_slot")
              asm.call("rt_list_read_slot")
              asm.push(:eax) # the item before
              asm.xchg(:bx, :di)
              asm.call("rt_list_slot")
              asm.call("rt_list_read_slot") # its number
              asm.xchg(:bx, :di)
              asm.pop(:edx)
              asm.cmp(kept.call(14, 16), 0)
              asm.jne("rt_list_sort_biggest_first")
              asm.cmp(:eax, kept.call(4, 32))
              asm.jle("rt_list_sort_place")
              asm.jmp("rt_list_sort_move")
              asm.label("rt_list_sort_biggest_first")
              asm.cmp(:eax, kept.call(4, 32))
              asm.jge("rt_list_sort_place")
              asm.label("rt_list_sort_move")
              asm.mov(:ax, kept.call(10, 16))
              asm.call("rt_list_slot")
              asm.call("rt_list_write_slot")
              asm.dec(kept.call(10, 16))
              asm.jmp("rt_list_sort_back")
              asm.label("rt_list_sort_place")
              asm.mov(:ax, kept.call(10, 16))
              asm.call("rt_list_slot")
              asm.mov(:edx, kept.call(0, 32))
              asm.call("rt_list_write_slot")
              asm.inc(kept.call(8, 16))
              asm.jmp("rt_list_sort_item")
              asm.label("rt_list_sort_done")
              asm.add(:sp, 16)
              asm.pop(:bp)
              asm.ret
            end

            # The game stopped: what went wrong, the list's place, and the numbers that give how, into FAULT for
            # a reader (Frame, CartridgeFaults), then rt_fault. An index outside a list has the index in EAX and
            # the list's length in ECX.
            def emit_faults(asm, memory)
              fault = ->(part) { X86.mem(nil, memory[Frame::FAULT] + part, size: 32) }
              asm.label("rt_list_index_fault")
              asm.mov(fault.call(0), CartridgeFaults::INDEX_OUT_OF_RANGE)
              asm.mov(fault.call(Frame::FAULT_FIRST), :eax)
              asm.mov(fault.call(Frame::FAULT_SECOND), :ecx)
              asm.jmp("rt_list_fault")

              asm.label("rt_list_full_fault")
              asm.mov(fault.call(0), CartridgeFaults::LIST_FULL)
              asm.xor(:eax, :eax)
              asm.mov(:ax, X86.mem(:bx, CAPACITY, size: 16))
              asm.mov(fault.call(Frame::FAULT_FIRST), :eax)
              asm.jmp("rt_list_fault")

              asm.label("rt_list_empty_fault")
              asm.mov(fault.call(0), CartridgeFaults::LIST_EMPTY)
              asm.movzx(:eax, :al) # which end: nought for the back
              asm.mov(fault.call(Frame::FAULT_FIRST), :eax)

              asm.label("rt_list_fault")
              asm.xor(:eax, :eax)
              asm.mov(:ax, :bx)
              asm.mov(fault.call(Frame::FAULT_LIST), :eax)
              asm.jmp("rt_fault")
            end
          end
        end
      end
    end
  end
end
