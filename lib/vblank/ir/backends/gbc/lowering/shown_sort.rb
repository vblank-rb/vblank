# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # A DRAW ORDER'S SORT THAT LEAVES OUT WHAT IS NOT SHOWING (IR ListSort's +shown+). Mixed into
          # Lowering, beside KeyedSort, whose sort it starts past the things not showing.
          #
          # A draw order of many things declared and a few showing is what a game with actors waiting in
          # the wings looks like, and a console's own games draw it by building their sprite list each
          # frame from what is showing: a thing that is not costs the test of whether it shows. So here
          # the things not showing are kept at the front of the order's list, its first entries, as the
          # interpreter keeps them (Reference#exec_list_sort), and how many they are is counted; the sort
          # starts past them, and the walk that places the sprites (Picture#emit_ordered_run), which reads
          # the list from its last entry, stops at them.
          #
          # Each pass asks every place whether it shows, a test of what the sprite is drawn by and one of
          # a byte that says whether it showed last pass. Only when one of those changes are the entries
          # moved: the ones not showing to the front, in the order they stood, the ones showing after
          # them, in theirs (#emit_shown_partition). One that shows again is then the back-most of those
          # showing, and the sort moves it forward past the things strictly behind it, so it stays behind
          # the things level with it, as the interpreter has it.
          #
          # THE WALK STOPS AT A MARK. Walking from the last entry, the walk would need a count of the
          # entries left, kept and taken down at every sprite placed, to know where to stop. Instead the
          # last entry not showing, the one just before the first showing, is taken out after the sort
          # and the number past the run's last sprite written in its slot: the walk's table sends that
          # number to a stop (Picture#emit_ordered_dispatch). The entry taken out is put back before the
          # list is next read, as the next pass's sort starts. The list is the framework's own, read by
          # the sort and the walk alone (LoweringPlan#sorts_kept_apart).
          #
          # A thing's number is worked out where its test finds it showing, rather than before the sort
          # for every place as the program writes it: the number of a thing not showing is never read
          # (IR ListSort), and nothing but the sort reads the list of numbers.
          module ShownSort
            # Where a sort handed +shown+ keeps its work, in work memory: +flags+, a byte a place, 1 while
            # it showed last pass; +hidden+, how many places are not showing, which is how many entries at
            # the front of the list they take; +changed+, set when a place comes or goes and cleared once
            # the list is moved round; +taken+, the entry the stop mark took the place of; +spare+, a copy
            # of the list as it is moved round. +keys+ is the program's write of each place's number, by
            # place, or nil where the sort does not make them. +marked+ is whether the walk stops at a
            # mark, which only a walk reading the list a slot an entry knows. +asked+ is whether each place
            # is asked, by place: a place known to show always is not, and is placed as any sprite is,
            # asked as it is placed.
            Kept = Data.define(:flags, :hidden, :changed, :taken, :spare, :keys, :marked, :asked)

            private

            # A Kept for every sort of the program handed +shown+, by the name of the list it sorts.
            def keep_shown_sorts
              @shown_sorts = {}
              @keys_set_by_sort = Set.new.compare_by_identity
              @reachable.each do |node|
                next unless node.kind == :list_sort && node.shown

                refuse_shown_sort_not_kept_apart!(node)
                @shown_sorts[node.name] = shown_sort_kept(node)
              end
            end

            def shown_sort_kept(node)
              count = node.shown.length
              keys = keys_set_by_shown_sort(node)
              keys&.each_value { |write| @keys_set_by_sort << write }
              Kept.new(flags: @memory.reserve("whether each place of #{node.name.inspect} showed", count),
                       hidden: @memory.reserve("how many places of #{node.name.inspect} are not showing", 1),
                       changed: @memory.reserve("whether a place of #{node.name.inspect} came or went", 1),
                       taken: @memory.reserve("the entry of #{node.name.inspect} a stop mark took", 1),
                       spare: @memory.reserve("the entries of #{node.name.inspect}, moved round", count),
                       keys: keys, marked: walks_stop_at_mark?(node.name),
                       asked: node.shown.map { |showing| folded(showing) != 1 })
            end

            # The sprites of +run+ its walk reaches only once its sort found them showing on this pass,
            # by name: every one the sort asks, in a run whose walk stops at the mark.
            def found_showing_by_sort(run)
              kept = @shown_sorts&.fetch(run.order, nil)
              return [] unless kept&.marked

              run.objects.select.with_index { |_name, place| kept.asked.fetch(place) }
            end

            # Whether every walk of the list +name+ reads it a slot an entry (Picture#emit_ordered_run),
            # so a stop mark in it ends the walk rather than stopping the game as a place naming none.
            def walks_stop_at_mark?(name)
              runs = @reachable.select { |node| node.kind == :present_objects }.flat_map { |node| node.orders || [] }
                               .select { |run| run.order == name }
              runs.all? { |run| order_read_by_slots?(run, front_dropped_lists) }
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

            # The builder hands +shown+ only to the sorts of its own draw orders, which are always kept
            # apart (LoweringPlan#sort_kept_apart?), the shape the sort here is written for.
            def refuse_shown_sort_not_kept_apart!(node)
              return if keyed_sort?(node)

              raise LoweringError, "the list #{node.name.inspect} is sorted with what shows, and is not a draw order's " \
                                   "own list. #{build_name} sorts with what shows only the list draw_in_order keeps."
            end

            # Whether the program's write +node+ is made by its sort instead (#emit_shown_marked).
            def key_set_by_sort?(node) = !@setting_sort_keys && @keys_set_by_sort&.include?(node)

            # The list as it starts: every place showing, none at the front not showing.
            def emit_shown_start(kept, count)
              @asm.load(:hl, kept.flags)
              @asm.load(:a, 1)
              count.times { @asm.load([:hli], :a) }
              @asm.xor_a(:a)
              @asm.load([kept.hidden], :a)
              @asm.load([kept.changed], :a)
            end

            # THE SORT, for a list handed +shown+: the stop mark taken out, each place asked, the list moved
            # round when one came or went, the sort past the entries not showing, and the mark put in.
            def emit_shown_keyed_sort(node, kept)
              slots = list_placed(node).first + Runtime::Lists::HEADER
              emit_stop_mark_taken_out(kept, slots) if kept.marked
              emit_shown_marked(node, kept)
              unchanged = fresh("sort_none_came_or_went")
              @asm.load(:a, [kept.changed])
              @asm.and_a(:a)
              @asm.jump(:z, unchanged)
              emit_shown_partition(kept, slots, node.shown.length)
              @asm.label(unchanged)
              emit_keyed_sort(node, kept)
              emit_stop_mark_put_in(kept, slots, node.shown.length) if kept.marked
            end

            # HL = the slot of the last entry not showing, from +slots+; Z set when every entry shows.
            def emit_last_hidden_slot(kept, slots)
              @asm.load(:a, [kept.hidden])
              @asm.and_a(:a)
              return unless block_given?

              skip = fresh("no_entry_hidden")
              @asm.jump(:z, skip)
              @asm.load(:e, :a)
              @asm.load(:d, 0)
              @asm.load(:hl, slots - 1)
              @asm.add_hl(:de)
              yield
              @asm.label(skip)
            end

            def emit_stop_mark_taken_out(kept, slots)
              emit_last_hidden_slot(kept, slots) do
                @asm.load(:a, [kept.taken])
                @asm.load([:hl], :a)
              end
            end

            # The number past the run's last sprite, +count+, which the walk's table sends to a stop.
            def emit_stop_mark_put_in(kept, slots, count)
              emit_last_hidden_slot(kept, slots) do
                @asm.load(:a, [:hl])
                @asm.load([kept.taken], :a)
                @asm.load([:hl], count)
              end
            end

            # Each place asked whether it shows, its flag kept up to date, the count of places not showing
            # with it, and +changed+ set where one came or went. A place known to show always is not asked:
            # its flag stays as it started. Where the sort makes the numbers, each is worked out where its
            # place shows.
            #
            # WHAT A PLACE DOES WHEN ITS FLAG TURNS OVER IS WRITTEN ONCE (#emit_flag_turned), and a place
            # tests its flag where it stands and calls that code only where it turned over. A pass where
            # nothing came or went runs the same instructions as with all of it written out, and a place
            # is eighteen bytes of this rather than forty: the Color sees its cartridge a bank of 16 KB at
            # a time, and every byte of a draw order's sort is a byte of the bank its scene must share.
            def emit_shown_marked(node, kept)
              shown_again = fresh("sort_flag_shown_again")
              gone = fresh("sort_flag_gone")
              marked_all = fresh("sort_places_marked")
              node.shown.each_with_index do |showing, place|
                next emit_sort_key_set(kept, place) if folded(showing) == 1

                emit_place_marked(showing, place, kept, shown_again, gone)
              end
              @asm.jump_relative(marked_all)
              emit_flag_turned(kept, shown_again, shows: true)
              emit_flag_turned(kept, gone, shows: false)
              @asm.label(marked_all)
            end

            # +place+ asked whether it shows, its number written where it does, its flag tested, and
            # #emit_flag_turned called where the flag says otherwise, with HL the flag.
            def emit_place_marked(showing, place, kept, shown_again, gone)
              hidden = fresh("sort_place_hidden")
              marked = fresh("sort_place_marked")
              emit_jump_unless_showing(showing, hidden)
              emit_sort_key_set(kept, place)
              @asm.load(:hl, kept.flags + place)
              @asm.load(:a, [:hl])
              @asm.and_a(:a)
              @asm.call(:z, shown_again)
              @asm.jump_relative(marked)
              @asm.label(hidden)
              @asm.load(:hl, kept.flags + place)
              @asm.load(:a, [:hl])
              @asm.and_a(:a)
              @asm.call(:nz, gone)
              @asm.label(marked)
            end

            # THE CODE A PLACE CALLS WHEN ITS FLAG TURNS OVER, at +label+, with HL the flag: the flag made
            # 1 where the place +shows+ again and 0 where it has gone, +changed+ set, and the count of
            # places not showing moved by one.
            def emit_flag_turned(kept, label, shows:)
              @asm.label(label)
              @asm.load([:hl], shows ? 1 : 0)
              @asm.load(:a, 1)
              @asm.load([kept.changed], :a)
              @asm.load(:hl, kept.hidden)
              shows ? @asm.dec([:hl]) : @asm.inc([:hl])
              @asm.ret
            end

            # On to +hidden+ unless +showing+ is 1, each test of it asked on its own where it is a product
            # of tests (Picture#emit_jump_unless_shown). A copy is asked, since a comparison made of it
            # takes it in.
            def emit_jump_unless_showing(showing, hidden)
              known = folded(showing)
              return @asm.jump(hidden) unless known.nil?

              emit_jump_unless_shown(value_node(showing.copy), hidden)
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
            # them in theirs. HL reads the copy, DE writes the list, C counts; each entry's flag is read
            # with B holding the entry.
            def emit_shown_partition(kept, slots, count)
              @asm.xor_a(:a)
              @asm.load([kept.changed], :a)
              copy = fresh("partition_copy")
              @asm.load(:hl, slots)
              @asm.load(:de, kept.spare)
              @asm.load(:c, count)
              @asm.label(copy)
              @asm.load(:a, [:hli])
              @asm.load([:de], :a)
              @asm.inc(:de)
              @asm.dec(:c)
              @asm.jump_relative(:nz, copy)
              @asm.load(:de, slots)
              emit_partition_pass(kept, count, :nz)
              emit_partition_pass(kept, count, :z)
            end

            # One pass over the copy, writing at DE every entry whose flag is not +skipped+'s answer: :nz
            # passes over the entries showing, :z over those not.
            def emit_partition_pass(kept, count, skipped)
              read = fresh("partition_read")
              passed = fresh("partition_passed")
              @asm.load(:hl, kept.spare)
              @asm.load(:c, count)
              @asm.label(read)
              @asm.load(:a, [:hli])
              @asm.push(:hl)
              @asm.load(:b, :a)
              emit_flag_of_entry(kept, count)
              @asm.and_a(:a)
              @asm.jump_relative(skipped, passed)
              @asm.load(:a, :b)
              @asm.load([:de], :a)
              @asm.inc(:de)
              @asm.label(passed)
              @asm.pop(:hl)
              @asm.dec(:c)
              @asm.jump_relative(:nz, read)
            end

            # A = the flag of the entry in B (and in A). HL is worked with.
            def emit_flag_of_entry(kept, count)
              if (kept.flags & 0xFF) + count <= 0x100
                @asm.add_a(kept.flags & 0xFF)
                @asm.load(:l, :a)
                @asm.load(:h, kept.flags >> 8)
              else
                @asm.load(:l, :a)
                @asm.load(:h, 0)
                @asm.push(:de)
                @asm.load(:de, kept.flags)
                @asm.add_hl(:de)
                @asm.pop(:de)
              end
              @asm.load(:a, [:hl])
            end
          end
        end
      end
    end
  end
end
