# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # A DRAW ORDER'S SORT WRITTEN OUT A PLACE AT A TIME (LoweringPlan#sorts_kept_apart). Mixed
          # into Lowering.
          #
          # A draw order is a list of bytes, each a thing's number, always as long as it can be, sorted
          # every pass by a list of numbers kept a slot a thing. The sort any list gets
          # (Lowering#emit_list_sort) keeps where it is and the item it is placing in quick memory and
          # works each slot's place out as it goes, about thirty instructions a thing on a pass where
          # nobody passed anybody. Here every place is
          # written out once as the cartridge is built, so the item at each place is read from an
          # address written in the code: the number of the item before it, the number of its own, one
          # compare. An item that does go back goes to a routine that moves it back past every item
          # whose number is strictly beyond its own, a place at a time, as the sort any list gets
          # does. The order the list ends in is that sort's, the interpreter's (Reference#exec_list_sort),
          # so nothing that reads it changes.
          #
          # AN ORDER THAT TURNS ROUND. Moving an item back a place at a time is a step for every pair
          # of things that passed each other, so when every thing passes every other (everything
          # flipped top to bottom) a pool of 32 is nearly 500 steps, far more than a frame holds. So
          # before an item goes back, the routine that turns a run round looks for a run
          # of three or more things each strictly beyond the next, from the item before it, and turns
          # the whole run over at once, half as many swaps as it is long. The sort then takes up again
          # at the place before the run, which the run's first item may still have to go back past.
          # Only a run strictly falling is turned, so two things level never swap and keep the order
          # they had. It is the Super Nintendo's way (SNES::Lowering#emit_keyed_run_reversal) written
          # for this processor; the decision to keep a draw order's sort apart is the shared one.
          module KeyedSort
            private

            # The numbers the routines that move an item back and turn a run round keep, in quick
            # memory: the place they are at (a byte), the item being moved or where the run starts (a
            # byte). The two never run at once.
            KEYED_SORT_NUMBERS = "the numbers a draw order's sort keeps"

            # Whether +node+ is sorted here: an order LoweringPlan#sorts_kept_apart takes whose items
            # are kept in a byte each, so a thing's number is one load.
            def keyed_sort?(node)
              _place, _capacity, width = list_placed(node)
              @plan.sorts_kept_apart.key?(node.name) && width == 1
            end

            def emit_keyed_sort(node)
              place, count, = list_placed(node)
              keys_place, _key_capacity, key_width = @lists.fetch(node.by)
              sort = KeyedOrder.new(slots: place + Runtime::Lists::HEADER, count: count,
                                    keys: keys_place + Runtime::Lists::HEADER, key_width: key_width,
                                    descending: node.descending, numbers_at: @memory.reserve_quick(KEYED_SORT_NUMBERS, 2))
              mover = fresh("sort_move")
              reversal = fresh("sort_reverse") if count > 2
              done = fresh("sort_done")
              starts = (1...count).to_h { |at| [at, fresh("sort_place")] }
              (1...count).each do |at|
                stays = fresh("sort_stays")
                @asm.label(starts.fetch(at))
                emit_keyed_compare_places(sort, at - 1, at)
                @asm.jump(:nc, stays)
                if reversal && at < count - 1
                  @asm.load(:a, at)
                  @asm.call(reversal)
                  @asm.jump(:c, starts.fetch([at - 1, 1].max))
                end
                @asm.load(:a, at)
                @asm.call(mover)
                @asm.label(stays)
              end
              @asm.jump(done)
              emit_keyed_move(sort, mover)
              emit_keyed_run_reversal(sort, reversal) if reversal
              @asm.label(done)
            end

            # Where a draw order's items and numbers are, and +numbers_at+, where in quick memory its
            # routines keep their two bytes. The list of numbers is as long as the order
            # (LoweringPlan#sort_kept_apart? holds to that), so +count+ is both lists' capacity.
            KeyedOrder = Data.define(:slots, :count, :keys, :key_width, :descending, :numbers_at)

            # Carry set when the item at place +at+ is to go back past the item at place +before+:
            # the number before is strictly beyond its own.
            def emit_keyed_compare_places(sort, before, at)
              @asm.load(:a, [sort.slots + before])
              emit_key_address(sort)
              @asm.load(:d, :h)
              @asm.load(:e, :l)
              @asm.load(:a, [sort.slots + at])
              emit_key_address(sort)
              emit_carry_when_beyond(sort)
            end

            # HL = where the number of the item in A is. BC is worked with. The numbers' slots in one
            # page of memory are reached with a byte sum.
            def emit_key_address(sort)
              shifts = sort.key_width.bit_length - 1
              if (sort.keys & 0xFF) + (sort.count * sort.key_width) <= 0x100
                shifts.times { @asm.add_a(:a) }
                @asm.add_a(sort.keys & 0xFF)
                @asm.load(:l, :a)
                @asm.load(:h, sort.keys >> 8)
              else
                @asm.load(:l, :a)
                @asm.load(:h, 0)
                shifts.times { @asm.add_hl(:hl) }
                @asm.load(:bc, sort.keys)
                @asm.add_hl(:bc)
              end
            end

            # Carry set when the number at DE, the item before's, is strictly beyond the one at HL:
            # bigger rising, smaller with +descending+. C, DE and HL are worked with. A byte is
            # compared with its top bit turned over, which makes the order of signed bytes the order
            # of unsigned ones. A wider number is the one's less the other's, a byte at a time from the
            # lowest, and the borrow out of it turned over when the two top bits differ.
            def emit_carry_when_beyond(sort)
              smaller, bigger = sort.descending ? %i[de hl] : %i[hl de]
              if sort.key_width == 1
                @asm.load(:a, [bigger])
                @asm.xor_a(0x80)
                @asm.load(:c, :a)
                @asm.load(:a, [smaller])
                @asm.xor_a(0x80)
                return @asm.cp_a(:c)
              end

              sort.key_width.times do |i|
                @asm.load(:a, [bigger])
                @asm.load(:c, :a)
                @asm.load(:a, [smaller])
                i.zero? ? @asm.sub_a(:c) : @asm.sbc_a(:c)
                next if i == sort.key_width - 1

                @asm.inc(smaller)
                @asm.inc(bigger)
              end
              @asm.sbc_a(:a) # every bit the borrow
              @asm.xor_a(:c) # ...turned over by the one top bit
              @asm.load(:c, :a)
              @asm.load(:a, [smaller])
              @asm.xor_a(:c) # ...and by the other's: its top bit gives the answer
              @asm.rla
            end

            # HL = the slot of place A, from +slots+ (the first slot, or one before it).
            def emit_keyed_slot(slots)
              @asm.load(:e, :a)
              @asm.load(:d, 0)
              @asm.load(:hl, slots)
              @asm.add_hl(:de)
            end

            # The routine that moves the item at place A back past every item before it whose number
            # is strictly beyond its own, each of those a place on. The place it is at and the item
            # are kept in quick memory.
            def emit_keyed_move(sort, mover)
              back = fresh("sort_back")
              put = fresh("sort_put")
              hole_at, item_at = sort.numbers_at, sort.numbers_at + 1
              @asm.label(mover)
              @asm.load_high(hole_at, :a)
              emit_keyed_slot(sort.slots)
              @asm.load(:a, [:hl])
              @asm.load_high(item_at, :a)
              @asm.label(back)
              @asm.load_high(:a, hole_at)
              @asm.and_a(:a)
              @asm.jump(:z, put)
              emit_keyed_slot(sort.slots - 1)
              @asm.load(:a, [:hl])
              emit_key_address(sort)
              @asm.load(:d, :h)
              @asm.load(:e, :l)
              @asm.load_high(:a, item_at)
              emit_key_address(sort)
              emit_carry_when_beyond(sort)
              @asm.jump(:nc, put)
              @asm.load_high(:a, hole_at)
              emit_keyed_slot(sort.slots - 1)
              @asm.load(:a, [:hli])
              @asm.load([:hl], :a)
              @asm.load_high(:a, hole_at)
              @asm.dec(:a)
              @asm.load_high(hole_at, :a)
              @asm.jump(back)
              @asm.label(put)
              @asm.load_high(:a, hole_at)
              emit_keyed_slot(sort.slots)
              @asm.load_high(:a, item_at)
              @asm.load([:hl], :a)
              @asm.ret
            end

            # The routine that turns a run round, called with A the place of an item that goes back
            # past the one before it, short of the last place. Carry clear when the item after it is
            # not strictly before it too, so the run is the two alone, and nothing is done. Otherwise
            # the run is found from the place before to the last place strictly before the one before
            # it, every pair of it swapped from the two ends in; carry set. Quick memory keeps where
            # the scan is and where the run starts.
            def emit_keyed_run_reversal(sort, reversal)
              scan = fresh("sort_scan")
              scanned = fresh("sort_scanned")
              turn = fresh("sort_turn")
              scan_at, first_at = sort.numbers_at, sort.numbers_at + 1
              @asm.label(reversal)
              @asm.load_high(scan_at, :a)
              @asm.dec(:a)
              @asm.load_high(first_at, :a)
              @asm.label(scan)
              @asm.load_high(:a, scan_at)
              @asm.cp_a(sort.count - 1)
              @asm.jump(:nc, scanned)
              emit_keyed_slot(sort.slots)
              @asm.load(:a, [:hli])
              @asm.push(:hl)
              emit_key_address(sort)
              @asm.pop(:bc)
              @asm.load(:d, :h)
              @asm.load(:e, :l)
              @asm.load(:a, [:bc])
              emit_key_address(sort)
              emit_carry_when_beyond(sort)
              @asm.jump(:nc, scanned)
              @asm.load_high(:a, scan_at)
              @asm.inc(:a)
              @asm.load_high(scan_at, :a)
              @asm.jump(scan)

              @asm.label(scanned)
              @asm.load_high(:a, first_at)
              @asm.inc(:a)
              @asm.load(:c, :a)
              @asm.load_high(:a, scan_at)
              @asm.cp_a(:c)
              @asm.ret(:z) # the run is the two: carry clear
              emit_keyed_slot(sort.slots) # DE = the run's last slot
              @asm.push(:hl)
              @asm.load_high(:a, first_at)
              emit_keyed_slot(sort.slots) # HL = its first
              @asm.pop(:de)
              @asm.label(turn)
              @asm.load(:a, [:hl])
              @asm.load(:c, :a)
              @asm.load(:a, [:de])
              @asm.load([:hli], :a)
              @asm.load(:a, :c)
              @asm.load([:de], :a)
              @asm.dec(:de)
              @asm.load(:a, :l)
              @asm.sub_a(:e)
              @asm.load(:a, :h)
              @asm.sbc_a(:d)
              @asm.jump(:c, turn)
              @asm.scf
              @asm.ret
            end
          end
        end
      end
    end
  end
end
