# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # A DRAW ORDER'S SORT THAT LEAVES OUT WHAT IS NOT SHOWING (IR ListSort's +shown+). Mixed into
          # Lowering, whose sort written in place (Lowering#emit_fixed_front_sort) it starts past the
          # things not showing.
          #
          # A draw order of many things declared and a few showing is what a game with actors waiting in
          # the wings looks like, and a console's own games draw it by building their sprite list each
          # frame from what is showing: a thing that is not costs the test of whether it shows. So here
          # the things not showing are kept at the front of the order's list, its first entries, as the
          # interpreter keeps them (Reference#exec_list_sort), and how many they are is counted, in a
          # number of the lowering's own that a value can read. The sort starts past them, and so does
          # the walk that places the sprites (Picture#emit_ordered_run).
          #
          # Each pass asks every place whether it shows, a test of what the sprite is drawn by and one of
          # a byte that says whether it showed last pass. Only when one of those changes are the entries
          # moved: the ones not showing to the front, in the order they stood, the ones showing after
          # them, in theirs (#emit_shown_partition). One that shows again is then the back-most of those
          # showing, and the sort moves it forward past the things strictly behind it, so it stays behind
          # the things level with it, as the interpreter has it.
          #
          # A thing's number is worked out where its test finds it showing, rather than before the sort
          # for every place as the program writes it: the number of a thing not showing is never read
          # (IR ListSort), and nothing but the sort reads the list of numbers.
          module ShownSort
            # Where a sort handed +shown+ keeps its work: +hidden+, the name of the number counting the
            # places not showing; +changed+, the name of the number set when a place comes or goes and
            # cleared once the list is moved round; +flags+, a byte a place in RAM, 1 while it showed
            # last pass; +spare+, where the list is copied as it is moved round. +keys+ is the program's
            # write of each place's number, by place, or nil. +asked+ is whether each place is asked: a
            # place known to show always is not.
            Kept = Data.define(:hidden, :changed, :flags, :spare, :keys, :asked)

            private

            # A Kept for every sort of the program handed +shown+, by the name of the list it sorts.
            def keep_shown_sorts
              @shown_sorts = {}
              @keys_set_by_sort = Set.new.compare_by_identity
              @program.walk.each do |node|
                next unless node.kind == :list_sort && node.shown

                refuse_shown_ring_sort!(node)
                @shown_sorts[node.name] = shown_sort_kept(node)
              end
            end

            def shown_sort_kept(node)
              count = node.shown.length
              keys = keys_set_by_shown_sort(node)
              keys&.each_value { |write| @keys_set_by_sort << write }
              Kept.new(hidden: keep_local(:hidden_in_order), changed: keep_local(:order_changed),
                       flags: @memory.reserve("whether each place of #{node.name.inspect} showed", count),
                       spare: @memory.reserve("the entries of #{node.name.inspect}, moved round",
                                              count * @lists.fetch(node.name).slot_bytes),
                       keys: keys, asked: node.shown.map { |showing| folded(showing) != 1 })
            end

            # The program's writes of the numbers +node+ sorts by, a place each, by place: the statements
            # just before it that write its list +by+ at a place written in the program, every place
            # once. Nil where they are not that, and the numbers are then written where the program
            # writes them.
            def keys_set_by_shown_sort(node)
              siblings = node.parent&.children or return nil
              before = siblings[0...siblings.index { |child| child.equal?(node) }]
              writes = before.reverse.take_while { |child| child.kind == :list_set && child.name == node.by }
              by_place = writes.to_h { |write| [folded(write.index), write] }
              by_place if by_place.keys.sort == (0...node.shown.length).to_a && by_place.length == writes.length
            end

            # A list something takes items from the front of goes round its slots and is sorted by the
            # runtime (rt_list_sort); the builder hands +shown+ only to the lists of its own draw orders,
            # which nothing does that to.
            def refuse_shown_ring_sort!(node)
              return unless [node.name, node.by].any? { |name| @lists_dropped_from_front.include?(name) }

              raise LoweringError, "the list #{node.name.inspect} is sorted with what shows, and the game takes items " \
                                   "from its front. The PlayStation build sorts such a list only when nothing does."
            end

            # Whether the program's write +node+ is made by its sort instead (#emit_shown_marked).
            def key_set_by_sort?(node) = !@setting_sort_keys && @keys_set_by_sort&.include?(node)

            # The sprites of +run+ its walk reaches only once its sort found them showing on this pass, by
            # name: every one the sort asks.
            def found_showing_by_sort(run)
              kept = @shown_sorts&.fetch(run.order, nil) or return []

              run.objects.select.with_index { |_name, place| kept.asked.fetch(place) }
            end

            # The list as it starts: every place showing, none at the front not showing.
            def emit_shown_start(kept, count)
              @asm.li(:t9, kept.flags)
              @asm.li(:v0, 1)
              count.times { |place| @asm.store(:sb, :v0, place, :t9) }
              emit_store_number(kept.hidden, 0)
              emit_store_number(kept.changed, 0)
            end

            # Each place asked whether it shows, its flag kept up to date, the count of places not showing
            # with it, and +changed+ set where one came or went; then the list moved round if one did. A
            # place known to show always is not asked: its flag stays as it started.
            #
            # WHAT A PLACE DOES WITH ITS ANSWER IS WRITTEN ONCE (#emit_flag_marking), and each place
            # calls it with the answer in a0: five instructions a place, where the whole of it written
            # out at every place was near thirty. The sort is straight code run once a pass, so every
            # byte of it is fetched from main RAM through the processor's 4 KB instruction cache each
            # pass (psx-spx, "Memory Map": the cache holds 4 KB of code in lines of 16 bytes): bytes
            # are time here as well as room, and a call that keeps an order a third shorter is cheaper
            # to run than the work written out.
            def emit_shown_marked(node, kept, list)
              marking = fresh_label("sort_flag_marking")
              marked_all = fresh_label("sort_places_marked")
              emit_push(:ra) # each place's call below sets ra
              node.shown.each_with_index do |showing, place|
                next emit_sort_key_set(kept, place) unless kept.asked.fetch(place)

                emit_place_marked(showing, place, kept, marking)
              end
              emit_pop(:ra)
              @asm.b(marked_all)
              emit_flag_marking(kept, marking)
              @asm.label(marked_all)
              unchanged = fresh_label("sort_none_came_or_went")
              jump_unless(Build.var_ref(kept.changed), unchanged)
              emit_shown_partition(kept, list)
              @asm.label(unchanged)
            end

            # +place+ asked whether it shows, its number written where it does, and #emit_flag_marking
            # called with a0 its answer: the place twice over, plus 1 where it shows.
            def emit_place_marked(showing, place, kept, marking)
              hidden = fresh_label("sort_place_hidden")
              answered = fresh_label("sort_place_answered")
              emit_jump_unless_showing(showing, hidden)
              emit_sort_key_set(kept, place)
              @asm.b(answered) { @asm.li(:a0, (place * 2) + 1) }
              @asm.label(hidden)
              @asm.li(:a0, place * 2)
              @asm.label(answered)
              @asm.jal(marking)
            end

            # THE CODE EACH PLACE CALLS, at +label+, with a0 its answer. Back at once where the place's
            # flag already says so; otherwise the flag turned over, the count of places not showing
            # moved by one, and +changed+ set. v0, v1 and t9 are worked with, and whatever setting a
            # number of the lowering's own works with.
            def emit_flag_marking(kept, label)
              same = fresh_label("sort_flag_same")
              gone = fresh_label("sort_flag_gone")
              @asm.label(label)
              @asm.andi(:v1, :a0, 1)                     # 1 where it shows
              @asm.srl(:a0, :a0, 1)                      # the place
              @asm.li(:t9, kept.flags)
              @asm.addu(:t9, :t9, :a0)
              @asm.lbu(:v0, 0, :t9)
              @asm.beq(:v0, :v1, same)
              @asm.sb(:v1, 0, :t9)
              emit_store_number(kept.changed, 1)
              @asm.beq(:v1, :zero, gone)
              statement(Build.set(kept.hidden, Build.binop(:-, Build.var_ref(kept.hidden), Build.int(1))))
              @asm.jr(:ra)
              @asm.label(gone)
              statement(Build.set(kept.hidden, Build.binop(:+, Build.var_ref(kept.hidden), Build.int(1))))
              @asm.label(same)
              @asm.jr(:ra)
            end

            # On to +hidden+ unless +showing+ is 1, each test of it asked on its own where it is a product
            # of tests (Backends::ShownWhen), so a pool's place is one compare of its count. A copy is
            # asked, since a comparison made of it takes it in.
            def emit_jump_unless_showing(showing, hidden)
              shown = ShownWhen.of(showing.copy) { |part| folded(part) }
              return jump_unless(Build.binop(:==, showing.copy, Build.int(1)), hidden) unless shown

              jump_unless(Build.binop(:==, shown.flag, Build.int(1)), hidden) if shown.flag
              shown.tests.each { |test| jump_unless(test, hidden) }
            end

            # The program's write of the number of +place+, where the sort makes it.
            def emit_sort_key_set(kept, place)
              write = kept.keys&.fetch(place, nil) or return

              @setting_sort_keys = true
              statement(write)
            ensure
              @setting_sort_keys = false
            end

            # THE LIST MOVED ROUND, on a pass where a place came or went: copied aside, then the entries not
            # showing written back from the front in the order they stood, then the entries showing after
            # them in theirs. t0 reads, t1 writes, t2 counts, t3 is the entry, t4 the flags.
            def emit_shown_partition(kept, list)
              emit_store_number(kept.changed, 0)
              load = Runtime::Lists::LOADS.fetch(list.slot_bytes)
              store = Runtime::Lists::STORES.fetch(list.slot_bytes)
              copy = fresh_label("partition_copy")
              @asm.li(:t0, list.address + Runtime::Lists::HEADER)
              @asm.li(:t1, kept.spare)
              @asm.li(:t2, list.capacity)
              @asm.label(copy)
              @asm.load(load, :t3, 0, :t0)
              @asm.addiu(:t0, :t0, list.slot_bytes)
              @asm.store(store, :t3, 0, :t1)
              @asm.addiu(:t2, :t2, -1)
              @asm.bne(:t2, :zero, copy) { @asm.addiu(:t1, :t1, list.slot_bytes) }
              @asm.li(:t1, list.address + Runtime::Lists::HEADER)
              @asm.li(:t4, kept.flags)
              emit_partition_pass(kept, list, load, store, written: 0)
              emit_partition_pass(kept, list, load, store, written: 1)
            end

            # One pass over the copy, writing at t1 every entry whose flag is +written+.
            def emit_partition_pass(kept, list, load, store, written:)
              read = fresh_label("partition_read")
              passed = fresh_label("partition_passed")
              @asm.li(:t0, kept.spare)
              @asm.li(:t2, list.capacity)
              @asm.label(read)
              @asm.load(load, :t3, 0, :t0)
              @asm.addu(:t5, :t4, :t3)
              @asm.load(:lbu, :t5, 0, :t5)
              @asm.addiu(:t5, :t5, -written)
              @asm.bne(:t5, :zero, passed)
              @asm.store(store, :t3, 0, :t1)
              @asm.addiu(:t1, :t1, list.slot_bytes)
              @asm.label(passed)
              @asm.addiu(:t2, :t2, -1)
              @asm.bne(:t2, :zero, read) { @asm.addiu(:t0, :t0, list.slot_bytes) }
            end
          end
        end
      end
    end
  end
end
