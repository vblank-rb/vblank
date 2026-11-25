# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # A draw order's sort that leaves out what is not showing (IR ListSort's +shown+). Mixed into
          # Lowering, whose sort kept in tables of its own (Lowering#emit_keyed_sort) it starts past the
          # things not showing.
          #
          # A draw order of many things declared and a few showing is what a game with actors waiting in
          # the wings looks like, and a console's own games draw it by building their sprite list each
          # frame from what is showing: a thing that is not costs the test of whether it shows. So here
          # the things not showing are kept in the order's first places, as the interpreter keeps them
          # at the front of its list (Reference#exec_list_sort), and twice how many they are is kept, the
          # first place showing as the tables index it. The sort starts past them, and so does the walk
          # that places the sprites (Picture#emit_ordered_run).
          #
          # Each pass asks every thing whether it shows, a test of what the sprite is drawn by and one of
          # a word that says whether it showed last pass. Only when one of those changes are the places
          # moved round: the things not showing to the front, in the order they stood, the ones showing
          # after them, in theirs (#emit_shown_partition). One that shows again is then the back-most of
          # those showing, and the sort moves it forward past the things strictly behind it, so it stays
          # behind the things level with it, as the interpreter has it. The asking is done on the game's
          # direct page, before a sort written in place moves D to its tables (Lowering#emit_sort_in_place).
          #
          # A thing's number is written into its place only when it shows: the number of a thing not
          # showing is never read (IR ListSort). The places of the things not showing hold the number
          # nothing is strictly behind instead (#emit_backmost_numbers), so the sort written for every
          # place stops at the first showing with nothing added to its compares.
          module ShownSort
            # Where a sort handed +shown+ keeps its work, in the first 8K: +flags+, a word a thing, by twice
            # the thing, 1 while it showed last pass; +hidden+, twice how many things are not showing;
            # +changed+, set when one comes or goes and cleared once the places are moved round; +spare+,
            # the items of the places as they are moved round. +asked+ is whether each thing is asked: a
            # thing known to show always is not.
            Kept = Data.define(:flags, :hidden, :changed, :spare, :asked)

            private

            # A Kept for every sort of the program handed +shown+, by the name of the list it sorts.
            def keep_shown_sorts
              @shown_sorts = {}
              @shown_sort_nodes = {}
              @program.walk.each do |node|
                next unless node.kind == :list_sort && node.shown

                refuse_shown_sort_not_kept!(node)
                @shown_sort_nodes[node.name] = node
                count = node.shown.length
                said = "the order #{node.name.inspect}"
                @shown_sorts[node.name] = Kept.new(flags: @memory.reserve("whether each thing of #{said} showed", count * 2),
                                                   hidden: @memory.reserve("the things of #{said} not showing", 2),
                                                   changed: @memory.reserve("whether a thing of #{said} came or went", 2),
                                                   spare: @memory.reserve("the items of #{said}, moved round", count * 2),
                                                   asked: node.shown.map { |showing| folded(showing) != 1 })
              end
            end

            # The builder hands +shown+ only to the sorts of its own draw orders, kept in tables of their
            # own while the first 8K has room for them (Lowering#keep_order_tables).
            def refuse_shown_sort_not_kept!(node)
              return if @keyed_sorts&.key?(node.name)

              raise LoweringError, "the draw order #{node.name.inspect} has no room for its tables in the first 8K of work " \
                                   "RAM. The Super Nintendo build sorts what shows only in those tables."
            end

            # The sprites of +run+ its walk reaches only once its sort found them showing on this pass, by
            # name: every one the sort asks, in a run read a place at a time.
            def found_showing_by_sort(run)
              kept = @shown_sorts&.fetch(run.order, nil) or return []

              run.objects.select.with_index { |_name, place| kept.asked.fetch(place) }
            end

            # The order as it starts: every thing showing, none in the first places not showing.
            def emit_shown_start(kept)
              @asm.lda(1)
              kept.asked.each_index { |item| @asm.sta(@asm.abs(kept.flags + (item * 2))) }
              @asm.stz(@asm.abs(kept.hidden))
              @asm.stz(@asm.abs(kept.changed))
            end

            # The things of +node+ asked, unless they were on this pass already (#emit_sort_in_place asks
            # them before it moves the direct page).
            def emit_shown_asked_once(node, kept, keyed)
              return if @shown_asked == node.name

              emit_shown_marked(node, kept, keyed)
              @shown_asked = node.name
            end

            # Each thing asked whether it shows, its flag kept up to date, the count of things not showing
            # with it, and +changed+ set where one came or went; then the places moved round if one did.
            #
            # What a thing does when its flag turns over is written once, past the things (#emit_count_moved):
            # a thing writes its flag where it stands and calls that code to set +changed+ and move the
            # count. A pass where nothing came or went runs what it did with all of it written out, and a
            # thing is under thirty bytes of this rather than more than fifty: the sort is written out a
            # thing at a time in the bank its code runs from, and every byte is a byte of that bank.
            def emit_shown_marked(node, kept, keyed)
              shown_again = fresh("sort_thing_shown_again")
              gone = fresh("sort_thing_gone")
              marked_all = fresh("sort_things_marked")
              node.shown.each_with_index do |showing, item|
                emit_thing_marked(showing, item, kept, shown_again, gone) if kept.asked.fetch(item)
              end
              @asm.brl(marked_all)
              emit_count_moved(kept, shown_again, step: -2)
              emit_count_moved(kept, gone, step: 2)
              @asm.label(marked_all)
              unchanged = fresh("sort_none_came_or_went")
              @asm.lda(@asm.abs(kept.changed))
              @asm.branch_long(:beq, unchanged)
              emit_shown_partition(kept, keyed)
              @asm.label(unchanged)
            end

            # +item+ asked whether it shows, its flag tested, and where the flag says otherwise the flag
            # written and #emit_count_moved called.
            def emit_thing_marked(showing, item, kept, shown_again, gone)
              hidden = fresh("sort_thing_hidden")
              marked = fresh("sort_thing_marked")
              flag = @asm.abs(kept.flags + (item * 2))
              emit_jump_unless_showing(showing, hidden)
              @asm.lda(flag)
              @asm.bne(marked)
              @asm.lda(1)
              @asm.sta(flag)
              @asm.jsr(@asm.abs(shown_again))
              @asm.bra(marked)
              @asm.label(hidden)
              @asm.lda(flag)
              @asm.beq(marked)
              @asm.stz(flag)
              @asm.jsr(@asm.abs(gone))
              @asm.label(marked)
            end

            # The code a thing calls when its flag turned over, at +label+, with A not nought: +changed+
            # set, and the count of things not showing (twice over, as the tables index them) moved by
            # +step+.
            def emit_count_moved(kept, label, step:)
              @asm.label(label)
              @asm.sta(@asm.abs(kept.changed))
              @asm.lda(@asm.abs(kept.hidden))
              step.abs.times { step.negative? ? @asm.dec(:a) : @asm.inc(:a) }
              @asm.sta(@asm.abs(kept.hidden))
              @asm.rts
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

            # A thing's number written only where it shows (Lowering#emit_key_by_place): on to past the
            # write when the thing's flag, just set by its asking, is nought.
            def emit_unless_hidden(kept, item)
              return yield unless kept.asked.fetch(item)

              past = fresh("number_of_hidden")
              @asm.lda(@asm.abs(kept.flags + (item * 2)))
              @asm.branch_long(:beq, past)
              yield
              @asm.label(past)
            end

            # The places moved round, on a pass where a thing came or went: the items copied aside, then
            # the ones not showing written back from the first place in the order they stood, then the ones
            # showing after them in theirs, and the table of places written again for every item. The
            # numbers are not moved: each thing showing writes its number into its place after this.
            def emit_shown_partition(kept, keyed)
              copy = fresh("partition_copy")
              rebuild = fresh("partition_places")
              last = keyed.count * 2
              @asm.stz(@asm.abs(kept.changed))
              @asm.ldx(0)
              @asm.label(copy)
              @asm.lda(@asm.abs_x(keyed.entries))
              @asm.sta(@asm.abs_x(kept.spare))
              2.times { @asm.inx }
              @asm.cpx(last)
              @asm.bcc(copy)
              @asm.ldy(0)
              emit_partition_pass(kept, keyed, :bne)
              emit_partition_pass(kept, keyed, :beq)
              @asm.ldx(0)
              @asm.label(rebuild)
              @asm.lda(@asm.abs_x(keyed.entries))
              @asm.tay
              @asm.txa
              @asm.sta(@asm.abs_y(keyed.places))
              2.times { @asm.inx }
              @asm.cpx(last)
              @asm.bcc(rebuild)
              emit_backmost_numbers(kept, keyed)
            end

            # The places of the things not showing given the number no thing is strictly behind (the
            # smallest there is, or the biggest when the biggest is in front), so the sort's compares and
            # its moving routine stop at the first thing showing with nothing more asked: a thing showing
            # whose own number is that one is level with them, and stays where it is.
            def emit_backmost_numbers(kept, keyed)
              fill = fresh("backmost_fill")
              filled = fresh("backmost_filled")
              low, high = keyed.descending ? [0xFFFF, 0x7FFF] : [0x0000, 0x8000]
              @asm.ldx(0)
              @asm.label(fill)
              @asm.cpx(@asm.abs(kept.hidden))
              @asm.bcs(filled)
              @asm.lda(low)
              @asm.sta(@asm.abs_x(keyed.lows))
              @asm.lda(high)
              @asm.sta(@asm.abs_x(keyed.highs))
              2.times { @asm.inx }
              @asm.bra(fill)
              @asm.label(filled)
            end

            # One pass over the items set aside, writing at Y every one whose flag does not send +passed_on+
            # past it: :bne passes over the things showing, :beq over those not.
            def emit_partition_pass(kept, keyed, passed_on)
              read = fresh("partition_read")
              passed = fresh("partition_passed")
              @asm.ldx(0)
              @asm.label(read)
              @asm.lda(@asm.abs_x(kept.spare))
              @asm.phx
              @asm.tax
              @asm.lda(@asm.abs_x(kept.flags))
              @asm.plx
              @asm.cmp(0)
              passed_on == :bne ? @asm.bne(passed) : @asm.beq(passed)
              @asm.lda(@asm.abs_x(kept.spare))
              @asm.sta(@asm.abs_y(keyed.entries))
              2.times { @asm.iny }
              @asm.label(passed)
              2.times { @asm.inx }
              @asm.cpx(keyed.count * 2)
              @asm.bcc(read)
            end

            # On to the compare at the place after the first showing: straight on where every thing shows,
            # and otherwise through a table of the places; on to +done+ when one thing shows or none.
            def emit_keyed_start_past_hidden(kept, keyed, starts, done)
              table = fresh("sort_starts")
              @asm.ldx(@asm.abs(kept.hidden))
              @asm.branch_long(:beq, starts.fetch(1))
              @asm.cpx((keyed.count - 1) * 2)
              @asm.branch_long(:bcs, done)
              @asm.jmp(@asm.ind_abs_x(table))
              @asm.label(table)
              # Twice the things not showing picks the place after the first showing; nought is not read.
              @asm.data_words((0...(keyed.count - 1)).map { |hidden| starts.fetch(hidden + 1) })
            end
          end
        end
      end
    end
  end
end
