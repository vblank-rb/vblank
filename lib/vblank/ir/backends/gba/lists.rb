# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A list is a block of 4-byte slots in IWRAM plus a hidden `length` variable, and it
        # is stored one of two ways depending on what the program does to it.
        #
        # A list that is shifted is a ring. Dropping from the front means the oldest item moves,
        # so the list keeps a `head` as well, and the item logically at position i sits in the
        # physical slot (head + i) & mask. The mask is what makes that wrap a single bitwise AND
        # rather than a division — which needs a power-of-two block, so a ring is given the next
        # power of two up and pays for the slots in between. It never holds more than it was
        # asked for; the extra slots exist only so the mask cannot point outside its own block.
        #
        # A list that is only indexed is a plain array, which is nearly all of them: a pool's
        # fields, a board, anything filled once and then read and written by number. Its head
        # can never move, so the physical slot is the index — no head to load, no wrap to do,
        # and no rounding to pay for. A pool of 145 slots takes 145 and not 256, which on a
        # cartridge with a lot of them is thousands of bytes of the console's 32K.
        #
        # Either way a bad index stays inside the list. The ring's mask confines it; the plain
        # array compares against its own length and reads slot nought instead. So an index off
        # the end can pick up a stale slot and can never reach a neighbouring variable. This
        # mirrors the interpreter's list (same items readable, same length, same overflow
        # point); the interpreter's friendly errors catch logic bugs in testing, and here the
        # hardware just stays bounded.
        #
        # A sprite's save-under backing buffer shares this file because it shares this
        # IWRAM allocation story — a name registered once, a layout looked up
        # afterward — not because it's a list; see #register_backing/#backing_info.
        class Lists
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[list_new list_push list_drop list_set list_fill list_sort list_pack stop_full].freeze

          def emit_statement(node)
            case node.kind
            when :list_new then emit_list_new(node)
            when :list_push then emit_list_push(node)
            when :stop_full then emit_stop_full(node)
            when :list_drop then emit_list_drop(node)
            when :list_set then emit_list_set(node)
            when :list_fill then emit_list_fill(node)
            when :list_sort then emit_list_sort(node)
            when :list_pack then emit_list_pack(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # The values this part works out (Lowering#values_written_by), each by its own method.
          VALUE_KINDS = %i[list_get list_len].freeze

          def emit_value(node)
            case node.kind
            when :list_get then eval_list_get(node)
            when :list_len then eval_list_len(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware
          include ShownSort

          # +bookkeeping+ is a checked build's (PassBookkeeping), which stops on a list read or
          # written past its end; nil for a cartridge for a player, which reads slot nought.
          def initialize(memory:, primitives:, emitter:, lowering:, placement:, bookkeeping: nil)
            @bookkeeping = bookkeeping
            @memory = memory
            @primitives = primitives
            @emitter = emitter
            @lowering = lowering
            @placement = placement
            @lists = {}
            @counter_owners = {} # a list's length and head variables -> the list
            @backing = {}
            @fills = false
            @copies = false
          end

          # The routine every list_fill calls, named once.
          FILL_ROUTINE = Messages::MadeNames.make(:list_fill_routine)

          # list_fill: +count+ items from +from+ set to one value, the way that many list_sets
          # would — and a bad index stays inside the list the same way: a run starting outside
          # it writes nothing, and one running off its end stops at the end. What it saves is
          # the per-item work: the run is handed to one routine that writes a word, four bytes,
          # at a time (see #emit_fill_routine), where a list_set per item works out an address
          # and stores one item each time.
          #
          # Only a plain array can be filled: a ring's items wrap round its block, so a run of
          # them is not a run of memory. Nothing builds a fill of one.
          def emit_list_fill(node)
            info = list_info(node.name)
            raise LoweringError, "list #{node.name.inspect} is shifted, so a run of it cannot be filled" if info[:ring]

            @fills = true
            skip = @emitter.gensym
            @lowering.value(node.value)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.count)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.from)                              # r0 = from
            @emitter.emit(ASM.pop(2))                               # r2 = count
            @emitter.emit(ASM.pop(3))                               # r3 = the value
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :lt)           # starts before the list
            # r12 is the address register, borrowed here for a count: the emitter forgets the
            # address it held the moment anything writes it.
            @emitter.emit_number(12, info[:capacity])
            @emitter.emit(ASM.sub_reg(12, 12, ACC))                 # r12 = items from +from+ to the end
            @emitter.emit(ASM.cmp_reg(2, 12))
            @emitter.emit(ASM.mov_reg_cond(:gt, 2, 12))             # stop at the end
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)           # nothing to write
            shift = Math.log2(info[:bytes]).to_i
            if shift.positive?
              @emitter.emit(ASM.lsl_imm(ACC, ACC, shift))           # r0 = from * item size
              @emitter.emit(ASM.lsl_imm(2, 2, shift))               # r2 = bytes to write
            end
            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.add_reg(TMP, LIST_ADDR, ACC))         # r1 = where the run starts
            emit_fill_pattern(info[:width])                         # r0 = the value in every byte place
            @placement.emit_call_cold_routine(FILL_ROUTINE)
            @emitter.place_label(skip)
          end

          # list_pack: every item of a list written into a byte list, lowest byte first. The
          # processor keeps a number in memory lowest byte first (GBATEK, "ARM CPU Overview": the
          # Advance runs little-endian), so a plain array's slots, side by side from its first,
          # already are those bytes, and the run is handed to the routine every list_copy calls
          # (#emit_copy_routine), which moves it a word at a time when it can. A byte at a time,
          # each shifted and set as the loops the step stands for do, is several instructions a
          # byte where the copy is a fraction of one.
          #
          # A bad run stays inside the list the way a list_set does: one starting before +into+ or
          # running past its length writes nothing. A ring, a pool's field, a list narrower or
          # wider than its slots, or a build checked against the interpreter (which stops at the
          # first bad index, as the loops' list_sets do) takes the loops instead.
          def emit_list_pack(node)
            from = list_info(node.name)
            into = list_info(node.into)
            return emit_list_pack_loops(node) unless block_copyable?(node, from, into)

            @copies = true
            skip = @emitter.gensym
            @lowering.value(node.at)                                         # r0 = the first byte's slot
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :lt)                    # starts before the list
            @primitives.load_var(2, length_var(node.name))
            shift = Math.log2(from[:bytes]).to_i
            @emitter.emit(ASM.lsl_imm(2, 2, shift)) if shift.positive?      # r2 = bytes to copy
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)                    # nothing to copy
            # The start held against the length less the run, which cannot wrap as the start plus
            # the run could (IR::ListPacking.fit_test).
            @primitives.load_var(TMP, length_var(node.into))
            @emitter.emit(ASM.sub_reg(3, TMP, 2))                            # r3 = the last start that fits
            @emitter.emit(ASM.cmp_reg(ACC, 3))
            @emitter.emit_branch(:bcond, skip, cond: :gt)                    # runs past its end
            @primitives.emit_list_base(into[:base])
            @emitter.emit(ASM.add_reg(TMP, LIST_ADDR, ACC))                  # r1 = where the run goes
            @primitives.emit_list_base(from[:base])
            @emitter.emit(ASM.mov_reg(ACC, LIST_ADDR))                       # r0 = the list's first slot
            @placement.emit_call_cold_routine(COPY_ROUTINE)
            @emitter.place_label(skip)
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, node.index)                           # left at nought, as the loops leave it
          end

          # The routine every list_copy calls, named once.
          COPY_ROUTINE = Messages::MadeNames.make(:list_copy_routine)

          # list_copy: the list made to hold +count+ entries of a table in the cartridge, from
          # the entry the game worked out. The start is held so the whole run is inside the
          # table, the same as the interpreter holds it, and the run always lands at the front
          # of the list — so a ring's head goes back to its first slot and the copy is still
          # one block of memory. The bytes are handed to one routine (see #emit_copy_routine).
          # The list of a group of `tile_pictures` is never written. Every picture is in the cartridge
          # in the form video memory keeps, so the copy that shows one is from there, and all a
          # "copy into the list" has to do is set where that picture starts: +held+ is each such
          # list's variable for it (see BackgroundDrawing#emit_copy_painted_run).
          attr_writer :held_tile_lists

          def emit_list_copy(node, table)
            info = list_info(node.name)
            # The builder refuses these (Builder#copy_table_run); this is the lowering's own
            # invariant, for a tree that reached it some other way — either would write past
            # the list into whatever memory follows it.
            unless table.elem_bytes == info[:bytes] && node.count.between?(1, [info[:capacity], table.count].min)
              raise LoweringError, "list #{node.name.inspect} cannot hold #{node.count} entries of table #{node.table.inspect}"
            end

            @copies = true
            @lowering.value(node.at)                                         # r0 = where the run starts
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))                     # not before the table
            @emitter.emit_number(TMP, table.count - node.count)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))                   # nor running off its end
            shift = Math.log2(table.elem_bytes).to_i
            @emitter.emit(ASM.lsl_imm(ACC, ACC, shift)) if shift.positive?   # r0 = its distance in bytes
            @emitter.emit_load_data_address(TMP, node.table)
            @emitter.emit(ASM.add_reg(ACC, TMP, ACC))                        # r0 = where it is in the cartridge
            held = (@held_tile_lists || {})[node.name]
            return @primitives.store_var(ACC, held) if held

            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.mov_reg(TMP, LIST_ADDR))                       # r1 = the list's first slot
            @emitter.emit_number(2, node.count * table.elem_bytes) # r2 = bytes to copy
            @placement.emit_call_cold_routine(COPY_ROUTINE)
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, head_var(node.name)) if info[:ring]
            @emitter.emit_number(ACC, node.count)
            @primitives.store_var(ACC, length_var(node.name))
          end

          # The registers a sort works in, beyond the four scratch ones: where the item being
          # placed is, where the list ends, the keys' first slot, that item, and the list's
          # first slot. They are saved and put back around it, since the code around may hold
          # its own things there.
          SORT_AT = 4
          SORT_END = 5
          SORT_KEYS = 6
          SORT_ITEM = 7
          SORT_FIRST = 8

          # list_sort: every item put in order by the number +by+ holds at it (Reference
          # #exec_list_sort), as an insertion sort written here in the program's own code, where
          # both lists' places are known when the cartridge is built. Each item in turn is taken
          # out and walked back past every item before it whose number is beyond its own — only
          # STRICTLY beyond, so level items keep their order — and put down where it stops. A list
          # already in order, which is what a draw order is on nearly every frame, is one compare
          # an item: about twenty instructions each, none of them a call.
          #
          # The walk goes by address rather than by index, a slot's width a step, so no index is
          # ever scaled; only an item, to find its number in +by+, is shifted by that list's width.
          # Every item is a place in +by+ (see IR ListSort), so none is checked.
          #
          # Only plain arrays are sorted: a shifted list's items wrap round its block, and nothing
          # builds a sort of one.
          def emit_list_sort(node)
            info = list_info(node.name)
            keys = list_info(node.by)
            [[node.name, info], [node.by, keys]].each do |name, each|
              raise LoweringError, "list #{name.inspect} is shifted, so it cannot be sorted" if each[:ring]
            end

            e = @emitter
            shown = shown_sort(node.name)
            emit_shown_marked(node, shown, info) if shown
            step = info[:bytes]
            outer = e.gensym
            inner = e.gensym
            place = e.gensym
            done = e.gensym
            stays = node.descending ? :ge : :le # the item before stays before when it is not beyond
            e.emit(ASM.push(SORT_AT, SORT_END, SORT_KEYS, SORT_ITEM, SORT_FIRST))
            e.emit_number(SORT_FIRST, info[:base])
            e.emit_number(SORT_KEYS, keys[:base])
            @primitives.load_var(SORT_END, length_var(node.name))
            shift = Math.log2(step).to_i
            e.emit(ASM.lsl_imm(SORT_END, SORT_END, shift)) if shift.positive?
            e.emit(ASM.add_reg(SORT_END, SORT_END, SORT_FIRST))     # past the last item
            if shown # the first entry showing is the first sorted, and nothing goes back past it
              e.emit_number(ACC, shown.block)
              e.emit(ASM.ldr_offset(ACC, ACC, ShownSort::HIDDEN))
              e.emit(ASM.lsl_imm(ACC, ACC, shift)) if shift.positive?
              e.emit(ASM.add_reg(SORT_FIRST, SORT_FIRST, ACC))
            end
            e.emit(ASM.add_imm(SORT_AT, SORT_FIRST, step))          # the second item is placed first
            e.place_label(outer)
            e.emit(ASM.cmp_reg(SORT_AT, SORT_END))
            e.emit_branch(:bcond, done, cond: :hs)
            emit_load_element(info, SORT_ITEM, SORT_AT)              # the item being placed
            emit_load_key(keys, ACC, SORT_ITEM)                      # r0 = its number
            e.emit(ASM.mov_reg(TMP, SORT_AT))                        # r1 = where it would go
            e.place_label(inner)
            e.emit(ASM.cmp_reg(TMP, SORT_FIRST))
            e.emit_branch(:bcond, place, cond: :eq)                  # nothing before it
            e.emit(ASM.sub_imm(HIGH, TMP, step))
            emit_load_element(info, SPARE, HIGH)                     # r2 = the item before
            emit_load_key(keys, HIGH, SPARE)                         # r3 = its number
            e.emit(ASM.cmp_reg(HIGH, ACC))
            e.emit_branch(:bcond, place, cond: stays)
            emit_store_element(info, SPARE, TMP)                     # it moves up a slot
            e.emit(ASM.sub_imm(TMP, TMP, step))
            e.emit_branch(:b, inner)
            e.place_label(place)
            emit_store_element(info, SORT_ITEM, TMP)
            e.emit(ASM.add_imm(SORT_AT, SORT_AT, step))
            e.emit_branch(:b, outer)
            e.place_label(done)
            e.emit(ASM.pop(SORT_AT, SORT_END, SORT_KEYS, SORT_ITEM, SORT_FIRST))
          end

          # The routine that copies a run: r0 where it comes from, r1 where it goes, r2 how many
          # bytes, more than nought. The copying engine moves a run without the processor, a
          # word or a half-word at a time, while a byte at a time is all the processor can do
          # in a loop — so the widest one the two addresses and the length all allow is taken:
          # words when all three are a whole number of words, half-words when they are a whole
          # number of halves, and bytes one at a time only for a run that is neither. A table
          # run starting at an entry the game works out is usually on a word, since entries
          # are picked by a number times the run's length. Touches r0 to r3 and nothing else,
          # and is emitted only in a program that copies.
          def emit_copy_routine
            return unless @copies

            e = @emitter
            halves = e.gensym
            bytes = e.gensym
            e.emit(ASM.loop_forever) # fall-through guard: only ever entered by a call
            e.place_label(COPY_ROUTINE)
            e.emit(ASM.orr_reg(3, ACC, TMP))
            e.emit(ASM.orr_reg(3, 3, 2))                                     # r3 = every address bit in play
            e.emit(ASM.tst_imm(3, 1))
            e.emit_branch(:bcond, bytes, cond: :ne)
            e.emit(ASM.tst_imm(3, 2))
            e.emit_branch(:bcond, halves, cond: :ne)
            e.emit(ASM.lsr_imm(3, 2, 2))                                     # words
            e.emit(ASM.orr_imm(3, 3, DMA_32BIT))
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            emit_start_engine_with_interrupts_held
            e.emit(ASM.return)
            e.place_label(halves)
            e.emit(ASM.lsr_imm(3, 2, 1))                                     # half-words
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            emit_start_engine_with_interrupts_held
            e.emit(ASM.return)
            e.place_label(bytes)
            e.emit(ASM.ldrb_offset(3, ACC, 0))
            e.emit(ASM.add_imm(ACC, ACC, 1))
            e.emit(ASM.strb_post(3, TMP, 1))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, bytes, cond: :ne)
            e.emit(ASM.return)
            # Where it ends, so a profile can say how much of a frame went into copying (see
            # GBA#lowered_routine_addresses).
            e.place_label(DerivedNames.routine_end(COPY_ROUTINE))
          end

          # The value in r3 repeated across a whole word in r0, so a word written anywhere in the
          # run holds the right item in each of its places.
          def emit_fill_pattern(width)
            case width
            when :byte
              @emitter.emit(ASM.and_imm(ACC, 3, 0xFF))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 8))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 16))
            when :half
              @emitter.emit(ASM.lsl_imm(ACC, 3, 16))
              @emitter.emit(ASM.lsr_imm(ACC, ACC, 16))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 16))
            when :word
              @emitter.emit(ASM.mov_reg(ACC, 3))
            end
          end

          # The routine that writes a run: r0 the word pattern, r1 where the run starts, r2 how
          # many bytes, more than nought. Bytes one at a time until the address is on a whole
          # word, then whole words, then the bytes left over. Each byte written alone is the
          # pattern's low byte, and the pattern is turned a byte along after it, so the next
          # address finds the byte that belongs there — which is what keeps a run of halves or
          # words right whichever byte it starts on. Touches r0 to r3 and nothing else, and is
          # emitted only in a program that fills.
          def emit_fill_routine
            return unless @fills

            e = @emitter
            e.emit(ASM.loop_forever) # fall-through guard: only ever entered by a call
            e.place_label(FILL_ROUTINE)
            lead = e.gensym
            words = e.gensym
            last_bytes = e.gensym
            done = e.gensym
            e.place_label(lead)
            e.emit(ASM.tst_imm(TMP, 3))
            e.emit_branch(:bcond, words, cond: :eq)               # on a whole word
            emit_fill_byte
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, done, cond: :eq)
            e.emit_branch(:b, lead)
            e.place_label(words)
            e.emit(ASM.cmp_imm(2, 4))
            e.emit_branch(:bcond, last_bytes, cond: :lt)          # less than a word left
            emit_fill_words_by_engine
            e.place_label(last_bytes)
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, done, cond: :eq)
            emit_fill_byte
            e.emit(ASM.sub_imm(2, 2, 1))
            e.emit_branch(:b, last_bytes)
            e.place_label(done)
            e.emit(ASM.return)
            # Where it ends, so a profile can say how much of a frame went into filling (see
            # GBA#lowered_routine_addresses).
            e.place_label(DerivedNames.routine_end(FILL_ROUTINE))
          end

          # The whole words of the run, handed to the copying engine rather than stored one at a
          # time: told to read the same word over and over, it writes it across the run with the
          # processor waiting, which is a few cycles a word where a store in a loop run from the
          # cartridge is several times that. The engine reads its word from memory, so the pattern
          # goes on the stack for it to read and comes back off after. r1 then points past the
          # words and r2 holds the bytes left, fewer than four, with the pattern as it was — a
          # whole number of words moves it round no places.
          def emit_fill_words_by_engine
            e = @emitter
            e.emit(ASM.push(ACC))                                   # the pattern, where the engine can read it
            e.emit(ASM.mov_reg(ACC, 13))                            # it reads from the stack...
            e.emit(ASM.lsr_imm(3, 2, 2))                            # ...this many words
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            e.emit(ASM.orr_imm(3, 3, DMA_32BIT))
            e.emit(ASM.orr_imm(3, 3, DMA_SRC_FIXED))
            emit_start_engine_with_interrupts_held
            e.emit(ASM.bic_imm(3, 2, 3))
            e.emit(ASM.add_reg(TMP, TMP, 3))                        # r1 past the words
            e.emit(ASM.and_imm(2, 2, 3))                            # r2 the bytes left
            e.emit(ASM.pop(ACC))
          end

          # Start the copying engine from r0 to r1 with the control word in r3, every register
          # as it was afterwards. The engine is set up in three writes and goes on the last, and
          # a routine answering an interrupt can use the same engine — a timer's handler that
          # fills or copies — so an interrupt between the writes would leave this one starting
          # with that one's addresses. So interrupts are held off for the three writes, and the
          # switch is put back as it was rather than turned on, which keeps it off where the
          # caller had it off. The processor waits while the engine runs, so the hold covers the
          # copy as well.
          #
          # The three writes are made by hand rather than through
          # Primitives#emit_start_copy_engine, which keeps the engine's address in r1 — and r1
          # is where this routine's destination is handed in.
          def emit_start_engine_with_interrupts_held
            e = @emitter
            e.emit(ASM.push(ACC, 2, 3))
            e.emit_number(2, REG_IME)
            e.emit(ASM.load_halfword(ACC, 2))
            e.emit(ASM.push(ACC))                                   # the interrupt switch as it was
            e.emit_number(ACC, 0)
            e.emit(ASM.store_halfword(ACC, 2))
            e.emit_number(2, REG_DMA3SAD)
            e.emit(ASM.ldr_offset(ACC, 13, 4))
            e.emit(ASM.str_offset(ACC, 2, 0))                       # from
            e.emit(ASM.str_offset(TMP, 2, Primitives::COPY_TO_STEP)) # to
            e.emit(ASM.ldr_offset(ACC, 13, 12))
            e.emit(ASM.str_offset(ACC, 2, Primitives::COPY_START_STEP)) # go; the processor waits
            e.emit(ASM.pop(ACC))
            e.emit_number(2, REG_IME)
            e.emit(ASM.store_halfword(ACC, 2))
            e.emit(ASM.pop(ACC, 2, 3))
          end

          # One byte of the pattern written, the address moved on, and the pattern turned a byte
          # along to match it.
          def emit_fill_byte
            @emitter.emit(ASM.strb_post(ACC, TMP, 1))
            @emitter.emit(ASM.lsr_imm(3, ACC, 8))
            @emitter.emit(ASM.orr_reg_lsl(ACC, 3, ACC, 24))
          end

          # Reserve a list's IWRAM layout: the slot block, then the head and length
          # variables. Called once per name during the definitions pass; a name
          # created twice with different capacities is a contradiction.
          #
          # +ring+ marks that the program shifts this one, so its head moves and its slots have to be
          # rounded up to a power of two for the wrapping mask. Everything else is a plain
          # array of exactly the slots it asked for.
          #
          # +fast+ is what the author set about where it should live: false for "I know
          # this is cold — give it room", true to insist on the quick memory, nil to let the
          # framework decide (see #place_list). +roomy+ is the framework's own decision, made
          # by {QuickMemoryPlan}, that the room is worth more to something else.
          #
          # +at+ is an address the list's slots are kept at instead of room of their own: words
          # something else already keeps (see Faces#corner_lists_in_words). Such a list is never
          # moved to the roomy memory.
          #
          # A pool's list kept in its layout's area (#reserve_pool_areas) has its slots there and
          # takes no room of its own.
          def register_list(name, capacity, ring: true, width: :word, fast: nil, roomy: false, at: nil)
            if (existing = @lists[name])
              return if existing[:capacity] == capacity && existing[:width] == width

              raise LoweringError,
                    "list #{name.inspect} is created with two different capacities " \
                    "(#{existing[:capacity]} and #{capacity})"
            end

            slots = Lists.slots_of(capacity, ring: ring)
            bytes = Build::ELEMENT_BYTES.fetch(width)
            want = Lists.slot_bytes(capacity, width, ring: ring)
            area = @pool_area_bases&.fetch(name, nil)
            base, in_roomy = if area
                               area
                             else
                               at ? [at, false] : place_list(name, want, roomy ? false : fast, ring: ring)
                             end
            fast = true if at # a pool's area moves as its block does (#reserve_pool_areas)
            # Placed before its counters are named, since where they go follows where it went.
            @lists[name] = { capacity: capacity, ring: ring, mask: slots - 1, base: base,
                             width: width, bytes: bytes, roomy: in_roomy, want: want, fast: fast }
            counters = ring ? [head_var(name), length_var(name)] : [length_var(name)] # a plain array's head can never move
            counters.each do |counter|
              @counter_owners[counter] = name
              @primitives.var_addr(counter)
            end
          end

          # How many slots a list of +capacity+ has: a ring's are rounded up to a power of two, so
          # its wrap is one AND.
          def self.slots_of(capacity, ring:) = ring ? Build.round_up_capacity(capacity) : capacity

          # The bytes a list's slots take, rounded up to a whole word so the next thing allocated
          # stays word-aligned — a narrow list is allowed to be an odd number of bytes long, but
          # nothing after it is.
          def self.slot_bytes(capacity, width, ring:)
            Memory.whole_words(slots_of(capacity, ring: ring) * Build::ELEMENT_BYTES.fetch(width))
          end

          # Everything one list takes, its slots and the counters that go where it goes (#register_list:
          # how many it holds, and a ring's oldest), read before the program is lowered by the
          # build's memory check (Console::AdvanceKit#list_bytes).
          def self.reserved_bytes(capacity, width, ring:)
            slot_bytes(capacity, width, ring: ring) + ((ring ? 2 : 1) * Memory::WORD)
          end

          # Whether +var+ is a number a collection in the roomy memory keeps for itself, and so
          # goes there with it (see Primitives#var_addr). For a list that is how many items it
          # holds and where its oldest is. For a pool it is every variable of its own — how many
          # are live, the first and last of its order, where each walk of it has got to — which
          # follow the list of which slots are live, the one every one of them is read beside.
          def roomy_counter?(var)
            owner = @counter_owners[var]
            kind, parts = Messages::MadeNames.read(var) unless owner
            owner = Messages::MadeNames.make(:pool_part, pool: parts[:pool], part: :active) if kind == :pool_part
            @lists.dig(owner, :roomy) || false
          end

          # Which memory this one goes in. The quick one unless the author marked that it does not
          # need to be there, or there is no longer room — and then the roomy one, which is
          # eight times the size and about six times the wait on a read.
          #
          # Nothing is moved to make space for another collection: the caller registers the
          # collections a frame touches first (see Roomy), so whatever is left when the quick
          # memory fills is the coldest thing the program has. Room for code is weighed before
          # this runs (see {QuickMemoryPlan}), and a collection that gives way to code comes
          # here already set to go to the roomy memory. Running out of both is a real
          # ceiling, and the message says which one gave way.
          def place_list(name, want, fast, ring: true)
            if fast == false || !@memory.room_for?(want)
              addr = @memory.alloc_roomy(want)
              return [addr, true] if addr

              raise LoweringError, no_room_message(name, want) if fast == false
            end
            return [@memory.alloc_near_base(want), false] if near_list?(name, want, ring)

            [@memory.alloc(want), false]
          end

          # The most bytes of slots kept beside the variables (#near_list?): a few small lists, so
          # the variables a game has stay within reach of their base however many such lists it has.
          NEAR_LIST_BYTES = 512

          # The lists the program reads and writes only at slots written in the program (`shown[1]`),
          # the ones a place beside the variables helps (#near_list?). A list also read at an index the
          # game works out keeps its place: that read wants the list's own base in its register, which
          # a slot reached from the variables' base would leave unloaded for it.
          def note_written_slot_lists(program)
            written = ->(node) { %i[list_get list_set].include?(node.kind) && node.index.kind == :int }
            naming = Hash.new { |names, name| names[name] = [] }
            program.walk do |node|
              node.attrs.each_value { |held| Array(held).grep(Symbol).each { |name| naming[name] << node } }
            end
            candidates = program.walk.filter_map { |node| node.name if written.call(node) }.uniq
            @written_slot_lists = candidates.select do |name|
              naming[name].all? { |node| node.kind == :list_new || written.call(node) }
            end.to_set
            @near_list_bytes = 0
          end

          # Does list +name+, of +want+ bytes, go beside the variables? A plain small list read at
          # written slots does: each such read is then one load from the variables' base, as a
          # variable's is (Primitives#emit_fixed_slot_base), where a list kept with the rest costs
          # its own base loaded first. A ring moves its slots, so it never does.
          def near_list?(name, want, ring)
            return false if ring || !@written_slot_lists&.include?(name) || @near_list_bytes + want > NEAR_LIST_BYTES

            @near_list_bytes += want
            true
          end

          # Said in the author's own words for it: a pool is several lists with names of the
          # framework's own, and the author declared one pool.
          def no_room_message(name, want)
            "#{Messages::MadeNames.collection_words(name)} needs #{want} bytes more and neither of the " \
              "console's work memories has room left. It has 32K of quick memory (which also holds the " \
              "code kept there) and 256K of roomy memory, and both are full. Use a smaller capacity, or " \
              "narrower items (`width: :byte`)."
          end

          # The collections in the quick memory that the framework may still move, and the room
          # each holds there: every one the author set nothing about. {Placement} weighs them
          # against the code that wants the same room.
          def movable_quick_lists
            @lists.reject { |_name, info| info[:roomy] || !info[:fast].nil? }.transform_values { |info| info[:want] }
          end

          # How many bytes a slot of each list is, by name: what one read of it moves.
          def list_widths = @lists.transform_values { |info| info[:bytes] }

          # The collections that ended up in the roomy memory, and how big each is — the
          # one thing a build report has to say about a decision nobody wrote.
          def roomy_lists
            @lists.select { |_name, info| info[:roomy] }
                  .to_h { |name, info| [name, info[:capacity] * info[:bytes]] }
          end

          # Where each list lives, for a finished cartridge to be asked about: the address of its
          # first slot, how many slots it may hold, how many bytes a slot is, and the address of
          # the number saying how many it holds now. A measurement that wants a list held full
          # writes that number (see Diagnostics::FullCollections), and nothing but this build
          # knows where it is.
          #
          # +slots+ is how many slots it really has, which is more than its capacity for a list the
          # game shifts from: those are rounded up to a power of two so the wrap is one AND, and
          # the oldest walks round all of them. +head_at+ is where such a list keeps the place of
          # its oldest, and nil for one that never moves it.
          #
          # +stride+ is how far apart its slots are and +scale+ what each value is kept multiplied by:
          # +bytes+ and 1, except a pool's list kept in its layout's area, whose slots are at the pool's
          # stride, +bytes+ the value's own width there, and a link kept as the slot times the stride.
          Place = Data.define(:base, :capacity, :bytes, :length_at, :slots, :head_at, :stride, :scale)

          def list_places
            @lists.to_h do |name, info|
              slot = slot_place(name, info)
              [name, Place.new(base: info[:base], capacity: info[:capacity], bytes: slot.width,
                               length_at: @primitives.vars.fetch(length_var(name)), slots: info[:mask] + 1,
                               head_at: (@primitives.vars.fetch(head_var(name)) if info[:ring]),
                               stride: slot.stride, scale: slot.scale)]
            end
          end

          # --- pools (Backends::PoolLayout) ---
          #
          # A pool is kept in the layout its placement gives: where slot s of each of its lists is, in
          # bytes from the list's first slot (PoolLayout::SlotPlace), and how wide its value is. Every
          # read and write of a slot by an index (#emit_slot_address, #written_slot_offset, and the
          # loads and stores at the slot's width) asks #slot_place for that, a pool's list and any other
          # alike. The Advance keeps every pool as lists today (Console::Description#pool_layouts): each
          # slot list a block of its own, slot s at s times its width. A walk of a pool kept so is
          # stepped by the statements the tree gives it (IR::WalkShape#step_statements).
          #
          # What the lists cost against the console's habit. An ARM game keeps a thing as a record and
          # holds its address in a register through the code that works on it, so a field is one LDR or
          # STR with an immediate offset from that base, and the next thing is the base plus the record's
          # size (GBATEK, "ARM Opcodes: Memory: Single Data Transfer",
          # https://problemkaputt.de/gbatek.htm#armopcodesmemorysingledatatransferldrstrpld). A field
          # kept as a list is reached from the thing's number instead: the number bounded, shifted by
          # the slot's width and added to the list's base before the load, and again for the store. A
          # layout of records is an adapter of PoolLayout and a base register held through a walk's body.
          #
          # Kept at one stride (:tables, :records), a pool's areas are reserved one after another in
          # one block before its lists are registered (#reserve_pool_areas), each list's slots at its
          # place there, so one register on a thing's slot in the first area reaches every field of it
          # at a distance written in the instruction (Statements#emit_stepped_walk).
          def place_pools(program)
            @slot_places = {}
            (program.pools || []).each do |shape|
              placement = pool_placement(program, shape)
              refuse_unmade_pool_placement!(shape, placement) if placement.layout == :lists
              @slot_places.merge!(placement.slots)
            end
          end

          # The placement +shape+ is kept in: the layout chosen for it, or :lists where its block
          # found no room in either memory (#reserve_pool_areas).
          def pool_placement(program, shape)
            placement = PoolLayout.chosen(shape, Console::ADVANCE, PoolLayout.steps_on(program, shape)).place(shape)
            return placement if placement.layout == :lists || @pool_blocks&.key?(shape.name)

            PoolLayout::ADAPTERS.fetch(:lists).place(shape)
          end

          # Each pool kept at one stride given its block, before any list is registered: the quick
          # memory where it has room and the pool is not one +roomy+ names or the author marked
          # cold, else the roomy one, else it keeps :lists. +roomy+ is the lists the plan sent to
          # the roomy memory.
          def reserve_pool_areas(program, roomy)
            @pool_area_bases = {}
            @pool_blocks = {}
            cold = program.walk.filter_map { |node| node.name if node.kind == :list_new && node.fast == false }
            (program.pools || []).each do |shape|
              placement = PoolLayout.chosen(shape, Console::ADVANCE, PoolLayout.steps_on(program, shape)).place(shape)
              next if placement.layout == :lists

              bytes = Memory.whole_words(placement.areas.values.sum { |area| Memory.whole_words(area) })
              block, in_roomy = pool_block_place(bytes, prefer_roomy: shape.slot_lists.keys.any? { |list| roomy.include?(list) || cold.include?(list) })
              next unless block

              @pool_blocks[shape.name] = block
              placement.areas.reduce(block) do |address, (area, area_bytes)|
                placement.slots.each { |list, slot| @pool_area_bases[list] = [address + slot.offset, in_roomy] if slot.area == area }
                address + Memory.whole_words(area_bytes)
              end
            end
          end

          # Where a pool's block of +bytes+ goes: [its address, whether in the roomy memory], or nil
          # where neither memory has room.
          def pool_block_place(bytes, prefer_roomy:)
            return [@memory.alloc(bytes), false] if !prefer_roomy && @memory.room_for?(bytes)

            roomy = @memory.alloc_roomy(bytes)
            roomy ? [roomy, true] : nil
          end

          # The address of the first of +pool+'s areas, which every field of a thing is reached from
          # at a distance, or nil for a pool kept as lists.
          def pool_block(pool) = @pool_blocks&.fetch(pool.to_sym, nil)

          # How far the slot of +list+ for a thing is from the thing's slot in its pool's first area.
          def field_distance(list) = list_info(list)[:base] - pool_block(DSL::Pool.owner_of_list(list))

          # Whether +list+ is one of +pool+'s lists kept in its block.
          # Only a list placed in the pool's block: a pool keeps lists of its own outside it too (the
          # colours it is drawn with, the copies its sprites show), each a plain list after its header.
          def pool_field?(list, pool)
            !pool_block(pool).nil? && (@pool_area_bases || {}).key?(list) &&
              DSL::Pool.owner_of_list(list).to_s == pool.to_s && @lists.key?(list)
          end

          # Where the slots of the list +name+ (its +info+) are: a pool's list as its layout placed it,
          # any other a slot of its width after another.
          def slot_place(name, info)
            (@slot_places || {}).fetch(name) do
              PoolLayout::SlotPlace.new(area: name, offset: 0, stride: info[:bytes], width: info[:bytes], scale: 1)
            end
          end

          # A placement the Advance cannot keep yet: an area that is not one list of the tree, a value
          # kept multiplied, or slots not one after another as wide as the list. Today's lists are
          # none of those.
          def refuse_unmade_pool_placement!(shape, placement)
            placement.slots.each do |list, slot|
              info = @lists[list] or next
              next if slot.area == list && slot.scale == 1 && slot.offset.zero? && slot.stride == slot.width &&
                      slot.width == info[:bytes]

              raise LoweringError, "Pool :#{shape.name} is kept as #{placement.layout}. The Game Boy Advance build keeps " \
                                   "a pool only as lists for now. To fix this, give the pool `layout: :lists`, or no layout."
            end
          end

          # A list's layout, or a friendly error if the program never created it.
          def list_info(name)
            @lists[name] ||
              raise(LoweringError,
                    "list #{name.inspect} was used before it was created — " \
                    "a `list #{name.inspect}, capacity: N` must run first")
          end

          # Reserve a backing buffer's RAM: a width×height block of 16-bit pixels in
          # the same IWRAM the variables live in. Allocated once per name during the
          # definitions pass; the block is padded to a whole word so the next
          # allocation stays word-aligned. A name declared twice with a different size
          # is a contradiction.
          def register_backing(name, width, height)
            if (existing = @backing[name])
              return if existing[:width] == width && existing[:height] == height

              raise LoweringError,
                    "backing buffer #{name.inspect} is declared with two different sizes " \
                    "(#{existing[:width]}x#{existing[:height]} and #{width}x#{height})"
            end

            base = @memory.alloc(((width * height * 2) + 3) & ~3) # bytes, rounded up to a word
            @backing[name] = { width: width, height: height, base: base }
          end

          # A backing buffer's layout, or a friendly error if it was never declared.
          def backing_info(name)
            @backing[name] ||
              raise(LoweringError,
                    "backing buffer #{name.inspect} was used before it was created — " \
                    "declare it first (a sprite does this for you)")
          end

          def head_var(name)
            DerivedNames.join(name, "__head")
          end

          def length_var(name)
            DerivedNames.join(name, "__len")
          end

          # list_new: reset the list to empty. Its storage is already reserved (see
          # register_list); this just zeroes head and length. The slot contents are
          # left as-is — nothing reads them until a push makes them live.
          #
          # A list full of a value holds all its items at once instead: its length is its
          # capacity, and every slot is set to the value by the routine a list_fill calls, a
          # whole word at a time — where pushing them would work out an address and store the
          # length again for each item. The console's memory is not zero at power-on, so a
          # list full of nought is filled all the same.
          def emit_list_new(node)
            info = list_info(node.name)
            shown = shown_sort(node.name)
            emit_shown_start(shown) if shown
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, head_var(node.name)) if info[:ring]
            if node.full_of
              @emitter.emit_number(ACC, info[:capacity])
              @primitives.store_var(ACC, length_var(node.name))
              slot = slot_place(node.name, info)
              if slot.stride == slot.width && slot.scale == 1
                emit_fill_from_first_slot(info, node.full_of)
              else
                emit_fill_at_stride(info, slot, node.full_of)
              end
            else
              @primitives.store_var(ACC, length_var(node.name))
            end
          end

          # Every one of a list's +capacity+ slots, from its first, set to the whole number
          # +value+ by the shared fill routine.
          def emit_fill_from_first_slot(info, value)
            @fills = true
            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.mov_reg(TMP, LIST_ADDR))              # r1 = the first slot
            @emitter.emit_number(3, value)
            emit_fill_pattern(info[:width])                         # r0 = the value in every byte place
            @emitter.emit_number(2, info[:capacity] * info[:bytes]) # r2 = bytes to write
            @placement.emit_call_cold_routine(FILL_ROUTINE)
          end

          # Every slot of a pool's list kept in its layout's area set to +value+, a slot at a time at
          # the pool's stride, the number kept multiplied where the slot keeps it so (a link, whose
          # NONE stays NONE).
          #
          # Four slots are written a turn, so a pool made full at power-on costs little more than a
          # word written a slot (the loop's count and branch spread over four stores), and the slots
          # left over after the last whole four are written after it.
          def emit_fill_at_stride(info, slot, value)
            again = @emitter.gensym
            number = value.negative? ? value : value * slot.scale
            turns, left = info[:capacity].divmod(FILL_SLOTS_A_TURN)
            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.mov_reg(TMP, LIST_ADDR))              # r1 = the first slot
            @emitter.emit_number(3, number)
            if turns.positive?
              @emitter.emit_number(2, turns)                        # r2 = turns left
              @emitter.place_label(again)
              FILL_SLOTS_A_TURN.times { emit_store_post(slot, 3) }
              @emitter.emit(ASM.subs_imm(2, 2, 1))
              @emitter.emit_branch(:bcond, again, cond: :ne)
            end
            left.times { emit_store_post(slot, 3) }
          end

          # How many slots a turn of #emit_fill_at_stride writes.
          FILL_SLOTS_A_TURN = 4

          # r+from+ stored at the slot r1 is at, at the slot's width, and r1 moved on a stride. A
          # halfword store moves its register on by 255 bytes at most, so a wider stride is a store and
          # an add.
          def emit_store_post(slot, from)
            if slot.width == 2 && slot.stride > 0xFF
              @emitter.emit(ASM.store_halfword_post(from, TMP, 0))
              return @primitives.emit_add_const(TMP, TMP, slot.stride, LIST_ADDR)
            end

            case slot.width
            when 4 then @emitter.emit(ASM.str_post(from, TMP, slot.stride))
            when 2 then @emitter.emit(ASM.store_halfword_post(from, TMP, slot.stride))
            when 1 then @emitter.emit(ASM.strb_post(from, TMP, slot.stride))
            end
          end

          # stop_full: a full pool told to stop. The cartridge has no way to stop with words yet, so
          # it writes nothing and the spawn is dropped, as a push onto a full list is (below).
          def emit_stop_full(_node) = nil

          # list_push: append at the tail — slot (head + length) & mask — then grow
          # length by one. If the list is already full the push is dropped rather than
          # overwriting the oldest item (hardware has no way to raise, so it stays
          # safe and quiet; the interpreter is what flags the overflow in testing).
          def emit_list_push(node)
            info = list_info(node.name)
            length = length_var(node.name)

            @primitives.load_var(ACC, length)            # r0 = length (the tail offset)
            @emitter.emit_number(TMP, info[:capacity])
            @emitter.emit(ASM.cmp_reg(ACC, TMP))                  # length - capacity
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :ge)         # full => drop the push

            emit_slot_address(info, node.name)         # r1 = &slot[(head+length)&mask]
            @emitter.emit(ASM.push(TMP))                          # hold the address across the value eval
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            emit_store_element(info, ACC, TMP)                    # slot = value

            @primitives.load_var(ACC, length)                        # length += 1
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, length)
            @emitter.place_label(skip)
          end

          # list_drop: remove one item. A shift (:front) advances head past the oldest
          # item; a pop (:back) just forgets the newest. Either way length shrinks by
          # one. An empty list is left untouched (length never goes negative).
          def emit_list_drop(node)
            info = list_info(node.name)
            head = head_var(node.name)
            length = length_var(node.name)

            @primitives.load_var(ACC, length)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq)         # empty => nothing to drop

            if node.from == :front
              @primitives.load_var(ACC, head)                        # head = (head + 1) & mask
              @emitter.emit(ASM.add_imm(ACC, ACC, 1))
              @primitives.emit_and_const(ACC, ACC, info[:mask], TMP)
              @primitives.store_var(ACC, head)
            end

            @primitives.load_var(ACC, length)                        # length -= 1
            @emitter.emit(ASM.sub_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, length)
            @emitter.place_label(skip)
          end

          # list_set: overwrite the item at an index. The masked address confines the
          # write to the list's own slots, so an out-of-range index scribbles a stale
          # slot at worst, never a neighbouring variable.
          def emit_list_set(node)
            return if key_set_by_sort?(node)

            info = list_info(node.name)
            slot = slot_place(node.name, info)
            if held_field?(node)
              @lowering.value(node.value)                   # r0 = value
              emit_value_scaled(slot)
              return emit_held_field_store(node, slot)
            end
            return emit_scaled_list_set(node, info, slot) if slot.scale > 1

            if (offset = written_slot_offset(info, slot, node.index))
              @lowering.value(node.value)                   # r0 = value
              # After the value, which may use r9 and r12 itself.
              base, distance = @primitives.emit_fixed_slot_base(info[:base] + offset, info[:base])
              @emitter.emit(ASM.str_offset(ACC, base, distance))
              return
            end

            @lowering.value(node.index)                     # r0 = index
            @bookkeeping&.emit_refuse_index_past_length(length_var(node.name), info[:base])
            emit_slot_address(info, node.name)         # r1 = &slot[(head+index)&mask]
            @emitter.emit(ASM.push(TMP))
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            emit_store_element(info, ACC, TMP, bytes: slot.width) # slot = value
          end

          # list_get: read the item at an index into the accumulator (a value).
          def eval_list_get(node)
            info = list_info(node.name)
            slot = slot_place(node.name, info)
            if held_field?(node)
              emit_held_field_load(node, slot)
              return emit_value_unscaled(slot)
            end
            return emit_fixed_slot_load(ACC, node) if fixed_slot_read?(node)

            @lowering.value(node.index)                     # r0 = index
            @bookkeeping&.emit_refuse_index_past_length(length_var(node.name), info[:base])
            emit_slot_address(info, node.name)         # r1 = &slot[(head+index)&mask]
            emit_load_element(info, ACC, TMP, bytes: slot.width) # r0 = slot
            emit_value_unscaled(slot)
          end

          # Whether +node+ reads a list's slot named by a number written in the program, which one
          # load reaches (#written_slot_offset), so it can stand where a variable's read can
          # (Expressions#one_load?).
          def fixed_slot_read?(node)
            return false unless node.kind == :list_get && @lists.key?(node.name) && !held_field?(node)

            info = list_info(node.name)
            slot = slot_place(node.name, info)
            slot.scale == 1 && !written_slot_offset(info, slot, node.index).nil?
          end

          # +reg+ = the slot +node+ reads (#fixed_slot_read?), in one load where the slot is beside
          # the variables (Primitives#emit_fixed_slot_base).
          def emit_fixed_slot_load(reg, node)
            info = list_info(node.name)
            offset = written_slot_offset(info, slot_place(node.name, info), node.index)
            base, distance = @primitives.emit_fixed_slot_base(info[:base] + offset, info[:base])
            @emitter.emit(ASM.ldr_offset(reg, base, distance))
          end

          # --- a walk holding a register on its thing (Statements#emit_stepped_walk) ---

          # The register a stepped walk holds on the thing it is on: the loop counter's register,
          # which a walk stepped so does not count in, and which nothing in a body LoopForm lets
          # keep its counter in registers can touch.
          THING = LoopForm::COUNTER

          # The walk whose thing THING holds while +block+ runs (IR::WalkShape).
          def with_held_walk(walk)
            outer = @held_walk
            @held_walk = walk
            yield
          ensure
            @held_walk = outer
          end

          # Whether a walk is holding THING on a thing now.
          def held_walk? = !@held_walk.nil?

          # r0 = the link +links+ of the held thing, as kept: the next thing's distance into the
          # pool's block, or -1 for NONE.
          def emit_held_link_read(links)
            base, distance = held_field_operand(field_distance(links), 2)
            @emitter.emit(ASM.ldrsh_offset(ACC, base, distance))
          end

          # Whether +node+ reads or writes a field of the thing the held walk is on.
          def held_field?(node)
            walk = @held_walk
            !walk.nil? && node.index.is_a?(Node) && node.index.kind == :var_ref && node.index.name == walk.at &&
              pool_field?(node.name, walk.pool)
          end

          # r0 = the held thing's field +node+ reads, one load at its distance from THING (LDR's
          # distance reaches 4095 bytes, LDRSH's and LDRSB's 255; past that, the address is made in
          # r1 first).
          def emit_held_field_load(node, slot)
            base, distance = held_field_operand(field_distance(node.name), slot.width)
            case slot.width
            when 4 then @emitter.emit(ASM.ldr_offset(ACC, base, distance))
            when 2 then @emitter.emit(ASM.ldrsh_offset(ACC, base, distance))
            when 1 then @emitter.emit(ASM.ldrsb_offset(ACC, base, distance))
            end
          end

          # The held thing's field +node+ writes = r0, the low bits its width keeps.
          def emit_held_field_store(node, slot)
            base, distance = held_field_operand(field_distance(node.name), slot.width)
            case slot.width
            when 4 then @emitter.emit(ASM.str_offset(ACC, base, distance))
            when 2 then @emitter.emit(ASM.store_halfword_offset(ACC, base, distance))
            when 1 then @emitter.emit(ASM.strb_offset(ACC, base, distance))
            end
          end

          # [the register, the distance] a load or store of +width+ bytes reaches a field +distance+
          # from THING through: THING itself where the instruction's distance reaches, else r1 made
          # THING plus the distance.
          def held_field_operand(distance, width)
            return [THING, distance] if distance <= (width == 4 ? 0xFFF : 0xFF)

            @emitter.emit_number(TMP, distance)
            @emitter.emit(ASM.add_reg(TMP, THING, TMP))
            [TMP, 0]
          end

          # A link kept as the slot times the stride (PoolLayout.strided_place), two bytes with NONE
          # as $FFFF: read with its sign, NONE is -1, and an arithmetic shift right brings any other
          # back to the slot and leaves -1 as it is.
          def emit_value_unscaled(slot)
            @emitter.emit(ASM.asr_imm(ACC, ACC, Math.log2(slot.scale).to_i)) if slot.scale > 1
          end

          # r0, a slot or NONE about to be written to a link kept multiplied, made the slot times the
          # stride where it is not below nought.
          def emit_value_scaled(slot)
            return unless slot.scale > 1

            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_reg_lsl_cond(:ge, ACC, ACC, Math.log2(slot.scale).to_i))
          end

          # A link kept multiplied written at an index, the value scaled as it goes in.
          def emit_scaled_list_set(node, info, slot)
            @lowering.value(node.index)
            @bookkeeping&.emit_refuse_index_past_length(length_var(node.name), info[:base])
            emit_slot_address(info, node.name)
            @emitter.emit(ASM.push(TMP))
            @lowering.value(node.value)
            emit_value_scaled(slot)
            @emitter.emit(ASM.pop(TMP))
            emit_store_element(info, ACC, TMP, bytes: slot.width)
          end

          # list_len: read the length variable into the accumulator (a value).
          def eval_list_len(node)
            list_info(node.name)
            @primitives.load_var(ACC, length_var(node.name))
          end

          private

          # Whether a list_pack's two lists are each a plain array whose slots sit side by side
          # from the first, as wide as the step says, the one written into of bytes.
          def block_copyable?(node, from, into)
            @bookkeeping.nil? && plain_array?(node.name, from) && plain_array?(node.into, into) &&
              from[:bytes] == ListPacking::WIDTH_BYTES.fetch(node.width) && into[:bytes] == 1
          end

          # Whether list +name+ (+info+ its layout) is never shifted and is no pool's field, so its
          # slots sit side by side from its first.
          def plain_array?(name, info) = !info[:ring] && !(@slot_places || {}).key?(name)

          def emit_list_pack_loops(node) = ListPacking.loops_for(node).each { |loop| @lowering.statement(loop) }

          # A slot named by a written number, in a list of words whose items never move (no ring) and
          # with no check on its length, is a fixed distance from the list's first slot: one load or
          # store from the list's base, where a worked-out index takes six instructions or more to
          # bound and scale. The byte offset, or nil where the slot must be found as the game runs
          # (a ring, a narrow list, a number past the capacity, which the bound sends to slot nought).
          def written_slot_offset(info, slot, index)
            return nil unless index.kind == :int && !info[:ring] && slot.width == 4 && @bookkeeping.nil?
            return nil unless index.value.between?(0, info[:capacity] - 1)

            offset = index.value * slot.stride # the list's base is its first slot, wherever its layout put it
            offset <= 0xFFF ? offset : nil
          end

          # Turn an offset (already in r0 — an index, or length for a push) into the physical
          # slot address. Clobbers r0/r1 and the list's address register; leaves the address
          # in TMP (r1), ready for ldr/str.
          #
          # A ring adds its head and wraps with the mask. A plain array's head can never move,
          # so the offset is the slot — which saves a variable read and an add on every access,
          # and costs a compare instead of the mask to keep a bad index inside the block.
          #
          # The list's own base is left where it was put and the slot address built somewhere
          # else, which is the whole reason a second touch of the same list is cheaper than
          # the first: the base outlives the access instead of being written over by its
          # answer. A variable has always worked this way — a register holds where the
          # variables start and each one rides a distance from it — and a list did not, so a
          # list rebuilt an address that had not changed since the cartridge was built, three
          # instructions at a time, in the hottest loop a game has.
          def emit_slot_address(info, name)
            if info[:ring]
              @primitives.load_var(TMP, head_var(name))            # r1 = head
              @emitter.emit(ASM.add_reg(ACC, TMP, ACC))            # r0 = head + offset
              @primitives.emit_and_const(ACC, ACC, info[:mask], TMP) # r0 = slot (ring-wrapped)
            else
              emit_bound_to_capacity(info[:capacity])              # r0 = slot, or nought
            end
            shift = Math.log2(slot_place(name, info).stride).to_i  # 4 bytes -> 2, 2 -> 1, 1 -> 0
            @emitter.emit(ASM.lsl_imm(ACC, ACC, shift)) if shift.positive? # r0 = slot * elem size
            @primitives.emit_list_base(info[:base])               # r9 = base address, often already there
            @emitter.emit(ASM.add_reg(TMP, LIST_ADDR, ACC))       # r1 = base + slot*size
          end

          # Load and store one element at the address in +addr+, at the list's own width. A
          # word list is one instruction either way; a narrower one is the same instruction
          # with the size bits set, so a narrow list is no slower to read or write — it is
          # only smaller.
          #
          # A narrow element is read back sign-extended, filling the whole register with the
          # number it holds including its sign, so what comes out of a byte slot holding -4 is
          # -4 and not 252. That is why there is no unsigned option: a slot that could not come
          # back negative would break every countdown written `sub` first and tested second.
          #
          # +bytes+ is the slot's width (#slot_place), the list's own unless a layout placed it.
          def emit_load_element(info, into, addr, bytes: info[:bytes])
            case bytes
            when 4 then @emitter.emit(ASM.ldr(into, addr))
            when 2 then @emitter.emit(ASM.ldrsh(into, addr))
            when 1 then @emitter.emit(ASM.ldrsb(into, addr))
            end
          end

          # +into+ = the number list +keys+ holds at the place in +item+: the place shifted by the
          # list's width and added to its first slot (in SORT_KEYS), then read at that width.
          def emit_load_key(keys, into, item)
            shift = Math.log2(keys[:bytes]).to_i
            if shift.positive?
              @emitter.emit(ASM.lsl_imm(into, item, shift))
              @emitter.emit(ASM.add_reg(into, into, SORT_KEYS))
            else
              @emitter.emit(ASM.add_reg(into, item, SORT_KEYS))
            end
            emit_load_element(keys, into, into)
          end

          # ...and the store, which keeps only the low bits that fit. A value too big for the
          # width is cut down rather than reaching the element next door — the same bargain
          # the index bound makes, and the interpreter cuts it down to exactly the same number.
          def emit_store_element(info, from, addr, bytes: info[:bytes])
            case bytes
            when 4 then @emitter.emit(ASM.str(from, addr))
            when 2 then @emitter.emit(ASM.store_halfword(from, addr))
            when 1 then @emitter.emit(ASM.strb(from, addr))
            end
          end

          # Hold r0 inside 0...capacity, reading slot nought for anything outside it. The
          # compare is unsigned, which is what catches a negative index too: as an unsigned
          # number it is enormous, so it fails the same test. Predicated rather than branched,
          # so there is no jump in the hottest thing a list does.
          def emit_bound_to_capacity(capacity)
            if ASM.encode_rotated_immediate(capacity)
              @emitter.emit(ASM.cmp_imm(ACC, capacity))
            else
              @emitter.emit_number(TMP, capacity)
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
            end
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, 0))
          end
        end
      end
    end
  end
end
