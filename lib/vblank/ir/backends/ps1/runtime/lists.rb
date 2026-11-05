# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE LISTS: a game's `list`, and every field of a pool, as the interpreter keeps them
          # (Reference::ListValue) — items added at the back and taken from either end, read and written
          # by index, and the game stopped, in the interpreter's words, by an index outside the list, an
          # item added to a full one or taken from an empty one.
          #
          # A list lives in the game's region of RAM (Memory#reserve): a header of four halfwords — its
          # capacity, where its first item is, how many items it holds, and how far to shift a slot's
          # number to get its place in bytes (0, 1 or 2 for slots of 1, 2 or 4 bytes) — and then its
          # slots. The items go round the slots like a ring, so taking one from the front moves where the
          # first item is rather than every item after it.
          #
          # A slot narrower than a word keeps the low bits of what goes in and reads back with its top bit
          # as the sign: 200 in a byte slot reads -56, as the interpreter has it. LB and LH widen by the
          # sign themselves.
          #
          # Every routine is handed the list's address in a0, and its other numbers in a1, a2, a3, t4,
          # t5. Each changes only the t registers and v0, and calls nothing, so none keeps a return
          # address.
          module Lists
            CAPACITY = 0
            FRONT = 2
            LENGTH = 4
            SHIFT = 6
            HEADER = 8

            # The load that reads one entry of a table, widened as the table keeps it, by the number the
            # lowering hands rt_list_copy (EntryKeeping#number).
            KEPT = { lb: 0, lbu: 1, lh: 2, lhu: 3, lw: 4 }.freeze

            # HOW A TABLE KEEPS AN ENTRY: its +bytes+ (1, 2 or 4) and whether it has a sign
            # (LoweringPlan#table_keeping). The one place that says which load reads one: LB and LH widen by
            # the sign, LBU and LHU with noughts.
            EntryKeeping = Data.define(:bytes, :signed) do
              def self.of(keeping) = new(bytes: keeping.first, signed: keeping.last)

              def load = { 1 => signed ? :lb : :lbu, 2 => signed ? :lh : :lhu, 4 => :lw }.fetch(bytes)

              # The number rt_list_copy is handed for it.
              def number = KEPT.fetch(load)
            end

            # A slot's size in bytes, by the end of the name of the routines that read and write slots of
            # that size directly (#emit_fixed_front_access).
            SLOT_SUFFIXES = { 1 => "byte", 2 => "half", 4 => "word" }.freeze
            LOADS = { 1 => :lb, 2 => :lh, 4 => :lw }.freeze
            STORES = { 1 => :sb, 2 => :sh, 4 => :sw }.freeze

            module_function

            def emit(asm, memory, direct_slot_sizes: [])
              emit_start(asm)
              emit_empty(asm)
              emit_push(asm)
              emit_drop(asm)
              emit_get_and_set(asm)
              emit_fixed_front_access(asm, direct_slot_sizes)
              emit_fill(asm)
              emit_copy(asm)
              emit_sort(asm)
              emit_faults(asm, memory)
            end

            # rt_lists_start: every list's header, from the table the lowering writes ("game_lists"): each
            # list's address (a word), its capacity and its shift (a halfword each), and an address of
            # nought after the last.
            def emit_start(asm)
              asm.label("rt_lists_start")
              asm.la(:t0, "game_lists")
              asm.label("rt_lists_start_next")
              asm.lw(:t1, 0, :t0)
              asm.beq(:t1, :zero, "rt_lists_start_done")
              asm.lhu(:t2, 4, :t0)
              asm.lhu(:t3, 6, :t0)
              asm.sh(:t2, CAPACITY, :t1)
              asm.sh(:t3, SHIFT, :t1)
              asm.b("rt_lists_start_next") { asm.addiu(:t0, :t0, 8) }
              asm.label("rt_lists_start_done")
              asm.jr(:ra)
            end

            # rt_list_empty: no items. rt_list_at_capacity: as many as it holds, from its first slot
            # (rt_list_fill then says what they are). rt_list_length: v0 = how many it holds.
            def emit_empty(asm)
              asm.label("rt_list_empty")
              asm.sh(:zero, FRONT, :a0)
              asm.jr(:ra) { asm.sh(:zero, LENGTH, :a0) }

              asm.label("rt_list_at_capacity")
              asm.lhu(:t0, CAPACITY, :a0)
              asm.sh(:zero, FRONT, :a0)
              asm.jr(:ra) { asm.sh(:t0, LENGTH, :a0) }

              asm.label("rt_list_length")
              asm.lhu(:v0, LENGTH, :a0)
              asm.jr(:ra)
            end

            # t9 = the address of the slot +offset+ (a register) places after the first item of the list at
            # +list+ (a0 unless said), unchecked. Changes t6 and t7.
            def emit_slot_of_offset(asm, offset, label, list: :a0)
              asm.lhu(:t6, FRONT, list)
              asm.lhu(:t7, CAPACITY, list)
              asm.addu(:t6, :t6, offset)
              asm.sltu(:t9, :t6, :t7)
              asm.bne(:t9, :zero, label)
              asm.subu(:t6, :t6, :t7) # once round the ring
              asm.label(label)
              asm.lhu(:t7, SHIFT, list)
              asm.sllv(:t6, :t6, :t7)
              asm.addu(:t9, list, :t6)
            end

            # +value+ into the slot at t9, as many bytes as its list's slots take. Changes t7.
            def emit_write_slot(asm, value, label)
              asm.lhu(:t7, SHIFT, :a0)
              asm.addiu(:t7, :t7, -1)
              asm.bltz(:t7, "#{label}_byte")
              asm.beq(:t7, :zero, "#{label}_half")
              asm.b("#{label}_done") { asm.sw(value, HEADER, :t9) }
              asm.label("#{label}_half")
              asm.b("#{label}_done") { asm.sh(value, HEADER, :t9) }
              asm.label("#{label}_byte")
              asm.sb(value, HEADER, :t9)
              asm.label("#{label}_done")
            end

            # v0 = what the slot at t9 of the list at +list+ (a0 unless said) holds, widened by its sign.
            # Changes t7.
            def emit_read_slot(asm, label, list: :a0)
              asm.lhu(:t7, SHIFT, list)
              asm.addiu(:t7, :t7, -1)
              asm.bltz(:t7, "#{label}_byte")
              asm.beq(:t7, :zero, "#{label}_half")
              asm.lw(:v0, HEADER, :t9)
              asm.b("#{label}_done")
              asm.label("#{label}_half")
              asm.lh(:v0, HEADER, :t9)
              asm.b("#{label}_done")
              asm.label("#{label}_byte")
              asm.lb(:v0, HEADER, :t9)
              asm.label("#{label}_done")
            end

            # An index in +index+ outside the list stops the game: compared as a number that cannot be
            # negative, an index below nought is past the end too. Changes t6 and t7.
            def emit_index_check(asm, index)
              asm.lhu(:t6, LENGTH, :a0)
              asm.sltu(:t7, index, :t6)
              asm.beq(:t7, :zero, "rt_list_index_fault") { asm.move(:t8, index) }
            end

            # rt_list_push(list, value): the value into the slot after the last item. A full list stops the game.
            def emit_push(asm)
              asm.label("rt_list_push")
              asm.lhu(:t0, LENGTH, :a0)
              asm.lhu(:t1, CAPACITY, :a0)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_list_full")
              emit_slot_of_offset(asm, :t0, "rt_list_push_within")
              emit_write_slot(asm, :a1, "rt_list_push_write")
              asm.addiu(:t0, :t0, 1)
              asm.jr(:ra) { asm.sh(:t0, LENGTH, :a0) }
            end

            # rt_list_drop(list, from): the first item taken (from 1) or the last (from 0). An empty list
            # stops the game.
            def emit_drop(asm)
              asm.label("rt_list_drop")
              asm.lhu(:t0, LENGTH, :a0)
              asm.beq(:t0, :zero, "rt_list_empty_fault")
              asm.addiu(:t0, :t0, -1)
              asm.sh(:t0, LENGTH, :a0)
              asm.beq(:a1, :zero, "rt_list_drop_done")
              asm.lhu(:t1, FRONT, :a0)
              asm.lhu(:t2, CAPACITY, :a0)
              asm.addiu(:t1, :t1, 1)
              asm.sltu(:t3, :t1, :t2)
              asm.bne(:t3, :zero, "rt_list_drop_front")
              asm.move(:t1, :zero)
              asm.label("rt_list_drop_front")
              asm.sh(:t1, FRONT, :a0)
              asm.label("rt_list_drop_done")
              asm.jr(:ra)
            end

            # rt_list_get(list, index): v0 = the item. rt_list_set(list, index, value). An index outside the
            # list stops the game before anything is read or written.
            def emit_get_and_set(asm)
              asm.label("rt_list_get")
              emit_index_check(asm, :a1)
              emit_slot_of_offset(asm, :a1, "rt_list_get_within")
              emit_read_slot(asm, "rt_list_get_read")
              asm.jr(:ra)

              asm.label("rt_list_set")
              emit_index_check(asm, :a1)
              emit_slot_of_offset(asm, :a1, "rt_list_set_within")
              emit_write_slot(asm, :a2, "rt_list_set_write")
              asm.jr(:ra)
            end

            # rt_list_get_byte (and _half, _word): rt_list_get for a list whose first item is always in its
            # first slot, with slots of that size (Lowering#list_routine): the index checked and the slot
            # read straight, with no ring to go round and no size to look up. rt_list_set_byte (and the
            # rest) write the same way. Only the sizes in +slot_sizes+ are made: those the game's lists have.
            def emit_fixed_front_access(asm, slot_sizes)
              SLOT_SUFFIXES.slice(*slot_sizes).each do |bytes, suffix|
                asm.label("rt_list_get_#{suffix}")
                emit_index_check(asm, :a1)
                asm.sll(:t9, :a1, bytes.bit_length - 1)
                asm.addu(:t9, :t9, :a0)
                asm.public_send(LOADS.fetch(bytes), :v0, HEADER, :t9)
                asm.jr(:ra)

                asm.label("rt_list_set_#{suffix}")
                emit_index_check(asm, :a1)
                asm.sll(:t9, :a1, bytes.bit_length - 1)
                asm.addu(:t9, :t9, :a0)
                asm.jr(:ra) { asm.public_send(STORES.fetch(bytes), :a2, HEADER, :t9) }
              end
            end

            # rt_list_fill(list, from, count, value): count items from +from+ set to the value. A count of
            # nought or less sets none; an index outside the list, first or last, stops the game before
            # anything is written.
            def emit_fill(asm)
              asm.label("rt_list_fill")
              asm.blez(:a2, "rt_list_fill_done")
              emit_index_check(asm, :a1)
              asm.addu(:t0, :a1, :a2)
              asm.addiu(:t0, :t0, -1)
              emit_index_check(asm, :t0)
              asm.move(:t0, :a1) # the next item
              asm.move(:t1, :a2) # how many are left
              asm.label("rt_list_fill_item")
              emit_slot_of_offset(asm, :t0, "rt_list_fill_within")
              emit_write_slot(asm, :a3, "rt_list_fill_write")
              asm.addiu(:t1, :t1, -1)
              asm.bne(:t1, :zero, "rt_list_fill_item") { asm.addiu(:t0, :t0, 1) }
              asm.label("rt_list_fill_done")
              asm.jr(:ra)
            end

            # rt_list_copy(list, table, kept, length, at, count): the list made to hold the run of the
            # table's +count+ entries from +at+, held so the run is inside the table (Reference
            # #exec_list_copy). +table+ (a1) is the table's address, +kept+ (a2) how it keeps an entry
            # (KEPT), +length+ (a3) how many entries it has, +at+ in t4 and +count+ in t5.
            def emit_copy(asm)
              asm.label("rt_list_copy")
              asm.subu(:t0, :a3, :t5) # the last start that keeps the run inside the table
              asm.bgez(:t0, "rt_list_copy_last")
              asm.move(:t0, :zero)
              asm.label("rt_list_copy_last")
              asm.bgez(:t4, "rt_list_copy_above")
              asm.move(:t4, :zero)
              asm.label("rt_list_copy_above")
              asm.slt(:t1, :t0, :t4)
              asm.beq(:t1, :zero, "rt_list_copy_start")
              asm.move(:t4, :t0)
              asm.label("rt_list_copy_start")
              asm.sh(:zero, FRONT, :a0)
              asm.sh(:t5, LENGTH, :a0)
              asm.blez(:t5, "rt_list_copy_done")
              asm.move(:t0, :zero) # the slot to write next
              asm.label("rt_list_copy_item")
              asm.addu(:t1, :t4, :t0) # the entry to read
              emit_copy_entry(asm)
              emit_slot_of_offset(asm, :t0, "rt_list_copy_within")
              emit_write_slot(asm, :v0, "rt_list_copy_write")
              asm.addiu(:t0, :t0, 1)
              asm.bne(:t0, :t5, "rt_list_copy_item")
              asm.label("rt_list_copy_done")
              asm.jr(:ra)
            end

            # rt_list_sort(list, keys, descending): every item of the list put in order by the number the
            # list +keys+ (a1) holds at it, the smallest first, or the biggest when +descending+ (a2) is not
            # nought (Reference#exec_list_sort). An insertion sort: each item in turn moves back past the
            # ones before it whose numbers are strictly beyond its own, so level items keep their order
            # and a list already in order costs a compare an item.
            #
            # This is the way for a list that items are taken from the front of, whose items go round its
            # slots, so each is found through the ring. A list whose first item stays in its first slot is
            # sorted by code the lowering writes where the sort is, with the places known
            # (Lowering#emit_fixed_front_sort).
            def emit_sort(asm)
              asm.label("rt_list_sort")
              asm.lhu(:t0, LENGTH, :a0)
              asm.li(:t1, 1) # the item to place next
              asm.slt(:t2, :t1, :t0)
              asm.beq(:t2, :zero, "rt_list_sort_done")
              asm.label("rt_list_sort_item")
              emit_slot_of_offset(asm, :t1, "rt_list_sort_item_within")
              emit_read_slot(asm, "rt_list_sort_item_read")
              asm.move(:t4, :v0) # the item
              emit_slot_of_offset(asm, :t4, "rt_list_sort_key_within", list: :a1)
              emit_read_slot(asm, "rt_list_sort_key_read", list: :a1)
              asm.move(:t5, :v0) # its number
              asm.move(:t3, :t1) # where it goes
              asm.label("rt_list_sort_step")
              asm.beq(:t3, :zero, "rt_list_sort_place")
              asm.addiu(:a3, :t3, -1)
              emit_slot_of_offset(asm, :a3, "rt_list_sort_before_within")
              emit_read_slot(asm, "rt_list_sort_before_read")
              asm.move(:t2, :v0) # the item before
              emit_slot_of_offset(asm, :t2, "rt_list_sort_before_key_within", list: :a1)
              emit_read_slot(asm, "rt_list_sort_before_key_read", list: :a1)
              asm.bne(:a2, :zero, "rt_list_sort_falling")
              asm.b("rt_list_sort_compared") { asm.slt(:t8, :t5, :v0) } # moves back past a bigger number
              asm.label("rt_list_sort_falling")
              asm.slt(:t8, :v0, :t5) # ...or past a smaller one
              asm.label("rt_list_sort_compared")
              asm.beq(:t8, :zero, "rt_list_sort_place")
              emit_slot_of_offset(asm, :t3, "rt_list_sort_move_within")
              emit_write_slot(asm, :t2, "rt_list_sort_move_write")
              asm.b("rt_list_sort_step") { asm.move(:t3, :a3) }
              asm.label("rt_list_sort_place")
              emit_slot_of_offset(asm, :t3, "rt_list_sort_place_within")
              emit_write_slot(asm, :t4, "rt_list_sort_place_write")
              asm.addiu(:t1, :t1, 1)
              asm.bne(:t1, :t0, "rt_list_sort_item")
              asm.label("rt_list_sort_done")
              asm.jr(:ra)
            end

            # v0 = entry t1 of the table at a1, widened by how it is kept (a2). Changes t2 and t3.
            def emit_copy_entry(asm)
              k = KEPT
              asm.sltiu(:t2, :a2, k[:lh])
              asm.bne(:t2, :zero, "rt_list_copy_entry_byte")
              asm.li(:t2, k[:lw])
              asm.beq(:a2, :t2, "rt_list_copy_entry_word")
              asm.sll(:t3, :t1, 1)
              asm.addu(:t3, :t3, :a1)
              asm.li(:t2, k[:lhu])
              asm.beq(:a2, :t2, "rt_list_copy_entry_unsigned_half")
              asm.lh(:v0, 0, :t3)
              asm.b("rt_list_copy_entry_done")
              asm.label("rt_list_copy_entry_unsigned_half")
              asm.lhu(:v0, 0, :t3)
              asm.b("rt_list_copy_entry_done")
              asm.label("rt_list_copy_entry_word")
              asm.sll(:t3, :t1, 2)
              asm.addu(:t3, :t3, :a1)
              asm.lw(:v0, 0, :t3)
              asm.b("rt_list_copy_entry_done")
              asm.label("rt_list_copy_entry_byte")
              asm.addu(:t3, :t1, :a1)
              asm.li(:t2, k[:lbu])
              asm.beq(:a2, :t2, "rt_list_copy_entry_unsigned_byte")
              asm.lb(:v0, 0, :t3)
              asm.b("rt_list_copy_entry_done")
              asm.label("rt_list_copy_entry_unsigned_byte")
              asm.lbu(:v0, 0, :t3)
              asm.label("rt_list_copy_entry_done")
            end

            # The game stopped: what went wrong, the list's address, and the numbers that say how, into
            # FAULT for the reader (Frame), then rt_fault (a0 = what went wrong).
            def emit_faults(asm, memory)
              fault = Runtime.at(memory, Frame::FAULT)
              asm.label("rt_list_full")
              asm.sw(:a0, fault + Frame::FAULT_LIST, :gp)
              asm.lhu(:t0, CAPACITY, :a0)
              asm.sw(:t0, fault + Frame::FAULT_FIRST, :gp)
              asm.j("rt_fault") { asm.li(:a0, Frame::LIST_FULL) }

              asm.label("rt_list_empty_fault")
              asm.sw(:a0, fault + Frame::FAULT_LIST, :gp)
              asm.sw(:a1, fault + Frame::FAULT_FIRST, :gp) # 1 taken from the front, 0 from the back
              asm.j("rt_fault") { asm.li(:a0, Frame::LIST_EMPTY) }

              # The index is in t8 (#emit_index_check).
              asm.label("rt_list_index_fault")
              asm.sw(:a0, fault + Frame::FAULT_LIST, :gp)
              asm.sw(:t8, fault + Frame::FAULT_FIRST, :gp)
              asm.lhu(:t0, LENGTH, :a0)
              asm.sw(:t0, fault + Frame::FAULT_SECOND, :gp)
              asm.j("rt_fault") { asm.li(:a0, Frame::INDEX_OUT_OF_RANGE) }
            end
          end
        end
      end
    end
  end
end
