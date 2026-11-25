# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # A sort that leaves out what is not showing (IR ListSort's +shown+). Mixed into Lowering.
          #
          # A draw order of many things declared and a few showing is what a game with actors waiting
          # in the wings looks like, and a console's own games draw it by building their sprite list
          # each frame from what is showing: a thing that is not costs the test of whether it shows.
          # So here the order is kept with the things not showing at its back, the first entries of
          # the list, as the interpreter keeps it (Reference#exec_list_sort), and how many they are is
          # counted; the sort then starts past them, and so does the walk that places the sprites
          # (Picture#emit_ordered_run).
          #
          # Each pass asks every place whether it shows, a test of what the sprite is drawn by and one
          # of a byte that says whether it showed last pass. Only when one of those changes are the
          # things moved: the ones not showing to the back, in the order they stood, the ones showing
          # after them, in theirs (#emit_shown_partition). One that shows again is then the back-most
          # of those showing, and the sort moves it forward past the things strictly behind it, so it
          # stays behind the things level with it, as the interpreter has it. A pass where nothing
          # came or went moves nothing, and a thing not showing costs its two tests.
          #
          # A thing's number is worked out where its test finds it showing, rather than before the
          # sort for every place as the program writes it: the order's numbers are the framework's own
          # list, read by the sort alone (LoweringPlan#sorts_kept_apart), and the number of a thing not
          # showing is never read (IR ListSort). So for an order kept in a table of its own the
          # program's writes of the numbers are made in the test (#keys_set_by_shown_sort).
          module ShownSort
            # Where a sort handed +shown+ keeps its work, each in work RAM: +flags+, a byte a place,
            # 1 while it showed last pass; +hidden+, a word, how many places are not showing, which is
            # how many entries at the front of the order they take; +changed+, a byte set when a place
            # comes or goes and cleared once the order is moved round; +bound+, the address of the order's first entry showing, for the
            # routine that moves an item back; +spare+, where the entries showing wait while the order
            # is moved round. +keys+ is the program's write of each place's number, by place, where
            # the sort makes them itself, or nil. +asked+ is whether each place is asked, by place: a
            # place known to show always is not, and is placed as any sprite is, asked as it is placed.
            Kept = Data.define(:flags, :hidden, :changed, :bound, :spare, :keys, :asked)

            private

            # A Kept for every sort of the program handed +shown+, by the name of the list it sorts.
            # +keyed+ is the sorts kept in a table of their own (Lowering#keep_order_tables).
            def keep_shown_sorts(keyed)
              @shown_sorts = {}
              @keys_set_by_sort = Set.new.compare_by_identity
              @program.walk.each do |node|
                next unless node.kind == :list_sort && node.shown

                refuse_shown_ring_sort!(node)
                @shown_sorts[node.name] = shown_sort_kept(node, keyed.key?(node.name))
              end
            end

            def shown_sort_kept(node, keyed)
              count = node.shown.length
              entry_bytes = keyed ? 2 : @lists.fetch(node.name)[2]
              keys = (keys_set_by_shown_sort(node) if keyed)
              keys&.each_value { |write| @keys_set_by_sort << write }
              Kept.new(flags: @memory.reserve("whether each place of #{node.name.inspect} showed", count),
                       hidden: @memory.reserve("how many places of #{node.name.inspect} are not showing", 2),
                       changed: @memory.reserve("whether a place of #{node.name.inspect} came or went", 2),
                       bound: @memory.reserve("the first entry of #{node.name.inspect} showing", 4),
                       spare: @memory.reserve("the entries of #{node.name.inspect} showing, moved round", count * entry_bytes),
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

            # A list something takes items from the front of goes round its slots, and its sort finds each
            # slot by index (Lowering#emit_ring_sort); the builder hands +shown+ only to the lists of its
            # own draw orders, which nothing does that to.
            def refuse_shown_ring_sort!(node)
              return unless @lists_dropped_from_front.include?(node.name)

              raise LoweringError, "the list #{node.name.inspect} is sorted with what shows, and the game takes items " \
                                   "from its front. The Genesis cartridge sorts such a list only when nothing does."
            end

            # Whether the program's write +node+ is made by its sort instead (#emit_shown_marked).
            def key_set_by_sort?(node) = !@setting_sort_keys && @keys_set_by_sort&.include?(node)

            # The order as it starts: every place showing, none at the front not showing, and the first
            # entry showing the first of +entries+.
            def emit_shown_start(kept, count, entries)
              (0...count).step(2) do |place|
                if place + 1 < count
                  @asm.move(:w, @asm.imm(0x0101), at(kept.flags, place))
                else
                  @asm.move(:b, @asm.imm(1), at(kept.flags, place))
                end
              end
              @asm.clr(:w, at(kept.hidden))
              @asm.clr(:b, at(kept.changed))
              @asm.lea(entries, @asm.a(0))
              @asm.move(:l, @asm.a(0), at(kept.bound))
            end

            # Each place asked whether it shows, its flag kept up to date, the count of places not
            # showing with it, and +changed+ set where one came or went. A place known to show always is
            # not asked: its flag stays as it started. Where the sort makes the numbers, each is worked
            # out where its place shows.
            #
            # What a place does when its flag turns over is written once (#emit_flag_turned), and a place
            # calls it with its answer in D0. A place still tests its own flag where it stands, so a pass
            # where it neither came nor went costs what it did with all of it written out; but a place
            # is half the bytes of that it was, and an order of a few dozen places a kilobyte smaller.
            def emit_shown_marked(node, kept)
              turned = fresh("sort_flag_turned")
              marked_all = fresh("sort_places_marked")
              node.shown.each_with_index do |showing, place|
                if folded(showing) == 1
                  emit_sort_key_set(kept, place)
                  next
                end

                emit_place_marked(showing, place, kept, turned)
              end
              @asm.bra(marked_all)
              emit_flag_turned(kept, turned)
              @asm.label(marked_all)
            end

            # +place+ asked whether it shows, its number written where it does, and #emit_flag_turned
            # called where its flag says otherwise, with D0 its place twice over, plus 1 where it shows.
            def emit_place_marked(showing, place, kept, turned)
              hidden = fresh("sort_place_hidden")
              call = fresh("sort_place_turned")
              marked = fresh("sort_place_marked")
              emit_jump_unless_showing(showing, hidden)
              emit_sort_key_set(kept, place)
              @asm.tst(:b, at(kept.flags, place))
              @asm.branch_near(:ne, marked)
              emit_flag_answer((place * 2) + 1)
              @asm.branch_near(:t, call)
              @asm.label(hidden)
              @asm.tst(:b, at(kept.flags, place))
              @asm.branch_near(:eq, marked)
              emit_flag_answer(place * 2)
              @asm.label(call)
              @asm.bsr(turned)
              @asm.label(marked)
            end

            # D0 = +answer+, in a word where it fits a MOVEQ and in a MOVE.W where it does not.
            def emit_flag_answer(answer)
              return @asm.moveq(answer, @asm.d(0)) if answer <= 127

              @asm.move(:w, @asm.imm(answer), @asm.d(0))
            end

            # The code a place calls when its flag turns over, at +label+, with D0 the place twice over,
            # plus 1 where it shows: the flag written, the count of places not showing moved by one, and
            # +changed+ set. D1 and A0 are worked with.
            def emit_flag_turned(kept, label)
              gone = fresh("sort_flag_gone")
              @asm.label(label)
              @asm.lsr(:w, 1, @asm.d(0))                  # D0 the place, and carry set where it shows
              @asm.scc(:cs, @asm.d(1))
              @asm.neg(:b, @asm.d(1))                     # 1 where it shows, 0 where it does not
              @asm.lea(at(kept.flags), @asm.a(0))
              @asm.move(:b, @asm.d(1), @asm.idx(0, 0, 0, :w))
              @asm.scc(:t, at(kept.changed))
              @asm.tst(:b, @asm.d(1))
              @asm.branch_near(:eq, gone)
              @asm.subq(:w, 1, at(kept.hidden))
              @asm.rts
              @asm.label(gone)
              @asm.addq(:w, 1, at(kept.hidden))
              @asm.rts
            end

            # On to +hidden+ unless +showing+ is 1: each test of it in place where it is a product of
            # tests (Picture#shown_when). A copy is asked, since a comparison made of it takes it in.
            def emit_jump_unless_showing(showing, hidden)
              known = folded(showing)
              return @asm.bra(hidden) unless known.nil?

              tests = shown_when(showing.copy)
              return emit_jump_unless_shown(tests, hidden, near: false) if tests

              jump_unless(Build.binop(:==, showing.copy, Build.int(1)), hidden)
            end

            # The program's write of the number of +place+, where the sort makes it.
            def emit_sort_key_set(kept, place)
              write = kept.keys&.fetch(place, nil) or return

              @setting_sort_keys = true
              statement(write)
            ensure
              @setting_sort_keys = false
            end

            # The order moved round, on a pass where a place came or went: the entries not showing to the
            # front, in the order they stood, then the entries showing, in theirs. +entries+ is the
            # operand of the first entry, each +size+ (:b, :w or :l) and its place shifted left by +shift+.
            # A0 reads every entry; one not showing is written at A1, one showing at A2 in the spare
            # room, and the ones showing are copied back after the rest. D7 counts down.
            def emit_shown_partition(kept, entries, count, size, shift)
              read = fresh("partition_read")
              showing = fresh("partition_showing")
              read_next = fresh("partition_next")
              copy = fresh("partition_copy")
              done = fresh("partition_done")
              @asm.clr(:b, at(kept.changed))
              @asm.lea(entries, @asm.a(0))
              @asm.movea(:l, @asm.a(0), @asm.a(1))
              @asm.lea(at(kept.spare), @asm.a(2))
              @asm.lea(at(kept.flags), @asm.a(3))
              @asm.move(:w, @asm.imm(count - 1), @asm.d(7))
              @asm.label(read)
              @asm.moveq(0, @asm.d(0))
              @asm.move(size, @asm.post(0), @asm.d(0))
              @asm.move(:l, @asm.d(0), @asm.d(1))
              @asm.lsr(:w, shift, @asm.d(1)) if shift.positive?
              @asm.tst(:b, @asm.idx(3, 0, 1, :w))
              @asm.branch(:ne, showing)
              @asm.move(size, @asm.d(0), @asm.post(1))
              @asm.bra(read_next)
              @asm.label(showing)
              @asm.move(size, @asm.d(0), @asm.post(2))
              @asm.label(read_next)
              @asm.dbra(@asm.d(7), read)
              @asm.lea(at(kept.spare), @asm.a(2))
              @asm.label(copy)
              @asm.cmp(:l, @asm.a(0), @asm.a(1))
              @asm.branch(:eq, done)
              @asm.move(size, @asm.post(2), @asm.post(1))
              @asm.bra(copy)
              @asm.label(done)
              emit_first_shown_entry(kept, entries, { b: 1, w: 2, l: 4 }.fetch(size))
              @asm.move(:l, @asm.a(0), at(kept.bound))
            end

            # A0 = the address of the first entry showing, entries of +bytes+ each from +entries+, and D3
            # how many bytes past the first entry it is. D0 is worked with.
            def emit_first_shown_entry(kept, entries, bytes)
              @asm.moveq(0, @asm.d(3))
              @asm.move(:w, at(kept.hidden), @asm.d(3))
              (bytes.bit_length - 1).times { @asm.add(:w, @asm.d(3), @asm.d(3)) }
              @asm.lea(entries, @asm.a(0))
              @asm.lea(@asm.idx(0, 0, 3, :w), @asm.a(0))
            end

            # On to the step of +steps+ (labels, one an entry from the first) that the first entry
            # showing starts at: straight on to the first where every entry shows, which is one test,
            # and otherwise through a table of them. The last step's label stands for there being none.
            # D0 and A0 are worked with.
            def emit_steps_past_hidden(kept, steps)
              @asm.tst(:w, at(kept.hidden))
              @asm.branch(:eq, steps.first)
              emit_step_picked_by_hidden(kept, steps)
            end

            # On to the step of +steps+ the count of entries not showing picks, through a table of them.
            def emit_step_picked_by_hidden(kept, steps)
              table = fresh("steps_past_hidden")
              @asm.moveq(0, @asm.d(0))
              @asm.move(:w, at(kept.hidden), @asm.d(0))
              @asm.lsl(:w, 2, @asm.d(0))
              @asm.lea(@asm.pc_rel(table), @asm.a(0))
              @asm.movea(:l, @asm.idx(0, 0, 0, :w), @asm.a(0))
              @asm.jmp(@asm.ind(0))
              @asm.label(table)
              @asm.data_longs(steps)
            end
          end
        end
      end
    end
  end
end
