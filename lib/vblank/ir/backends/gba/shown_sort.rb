# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A DRAW ORDER'S SORT THAT LEAVES OUT WHAT IS NOT SHOWING (IR ListSort's +shown+). Mixed into
        # Lists, whose sort it starts past the things not showing.
        #
        # A draw order of many things declared and a few showing is what a game with actors waiting in
        # the wings looks like, and a console's own games draw it by building their sprite list each
        # frame from what is showing: a thing that is not costs the test of whether it shows. So here
        # the things not showing are kept at the front of the order's list, its first entries, as the
        # interpreter keeps them (Reference#exec_list_sort), and how many they are is counted. The sort
        # starts past them, and so does the copy of the run into the sprite table
        # (SpriteDrawing#emit_copy_draw_run), which reads the list from its last entry and stops there.
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
          # Where a sort handed +shown+ keeps its work, one block of work memory: how many places are
          # not showing (a word, at HIDDEN), whether a place came or went since the list was last moved
          # round (a word, at CHANGED), where in the sprite table the run's copy stopped last pass (a
          # word, at ROWS_END), then a byte a place, 1 while it showed last pass (from FLAGS).
          # +spare+ is where the list is copied as it is moved round. +keys+ is the program's write of
          # each place's number, by place, or nil where the sort does not make them. +asked+ is whether
          # each place is asked: a place known to show always is not.
          Kept = Data.define(:block, :spare, :count, :keys, :asked)

          HIDDEN = 0
          CHANGED = 4
          ROWS_END = 8
          FLAGS = 12

          LINK = 14 # The link register, which a call sets to the address it comes back to

          # A Kept for every sort of +program+ handed +shown+, by the name of the list it sorts, in
          # +memory+. +known+ answers a value the build already knows, or nil.
          def self.plan(program, memory:, &known)
            program.walk.select { |node| node.kind == :list_sort && node.shown }.to_h do |node|
              count = node.shown.length
              keys = keys_set_by(node, &known)
              [node.name, Kept.new(block: memory.alloc(FLAGS + count), spare: memory.alloc(count * 2), count: count,
                                   keys: keys, asked: node.shown.map { |showing| known.call(showing) != 1 })]
            end
          end

          # The program's writes of the numbers +node+ sorts by, a place each, by place: the statements
          # just before it that write its list +by+ at a place written in the program, every place
          # once. Nil where they are not that, and the numbers are then written where the program
          # writes them.
          def self.keys_set_by(node, &known)
            siblings = node.parent&.children or return nil
            before = siblings[0...siblings.index { |child| child.equal?(node) }]
            writes = before.reverse.take_while { |child| child.kind == :list_set && child.name == node.by }
            by_place = writes.to_h { |write| [known.call(write.index), write] }
            by_place if by_place.keys.sort == (0...node.shown.length).to_a && by_place.length == writes.length
          end

          # The sorts handed +shown+ (ShownSort.plan), and the expressions a place's test is branched on.
          attr_writer :expressions

          def shown_sorts=(sorts)
            @shown_sorts = sorts
            @keys_set_by_sort = Set.new.compare_by_identity
            sorts.each_value { |kept| kept.keys&.each_value { |write| @keys_set_by_sort << write } }
          end

          def shown_sort(name) = @shown_sorts&.fetch(name, nil)

          private

          # Whether the program's write +node+ is made by its sort instead (#emit_shown_marked).
          def key_set_by_sort?(node) = !@setting_sort_keys && @keys_set_by_sort&.include?(node)

          # The list as it starts: every place showing, none at the front not showing.
          def emit_shown_start(kept)
            e = @emitter
            e.emit_number(TMP, kept.block)
            e.emit_number(ACC, 0)
            e.emit(ASM.str_offset(ACC, TMP, HIDDEN))
            e.emit(ASM.str_offset(ACC, TMP, CHANGED))
            e.emit(ASM.str_offset(ACC, TMP, ROWS_END))
            e.emit_number(ACC, 1)
            kept.count.times { |place| e.emit(ASM.strb_offset(ACC, TMP, FLAGS + place)) }
          end

          # Each place asked whether it shows, its flag kept up to date, the count of places not showing
          # with it, and CHANGED set where one came or went; then the list moved round if one did. A place
          # known to show always is not asked: its flag stays as it started.
          #
          # WRITTEN ONCE, CALLED FROM EACH PLACE. What a place does with its answer (read its flag, and
          # where the flag turned over, write it, move the count and set CHANGED) is the same for every
          # place but the flag's offset, so it is one stretch of code at the end (#emit_flag_marking),
          # which each place calls with its answer: four instructions a place, where the whole of it
          # written out at every place was more than twenty. The sort runs every frame, so the build
          # wants it in the console's quick memory (GBA::Placement), and every byte it takes there is
          # one another routine that runs every frame cannot have: written out at every place, a
          # draw order of a few dozen places grew by kilobytes and pushed such routines out.
          def emit_shown_marked(node, kept, info)
            e = @emitter
            marking = e.gensym
            marked_all = e.gensym
            e.emit(ASM.push(LINK)) # each place's call below sets the link register
            node.shown.each_with_index do |showing, place|
              next emit_sort_key_set(kept, place) unless kept.asked.fetch(place)

              emit_place_marked(showing, place, kept, marking)
            end
            e.emit(ASM.pop(LINK))
            e.emit_branch(:b, marked_all)
            emit_flag_marking(kept, marking)
            e.place_label(marked_all)
            unchanged = e.gensym
            e.emit_number(TMP, kept.block)
            e.emit(ASM.ldr_offset(ACC, TMP, CHANGED))
            e.emit(ASM.cmp_imm(ACC, 0))
            e.emit_branch(:bcond, unchanged, cond: :eq)
            emit_shown_partition(kept, info)
            e.place_label(unchanged)
          end

          # +place+ asked whether it shows, its number written where it does, and #emit_flag_marking
          # called with its answer: its flag's offset twice over, plus 1 where it shows.
          def emit_place_marked(showing, place, kept, marking)
            e = @emitter
            hidden = e.gensym
            answered = e.gensym
            emit_branch_unless_showing(showing, hidden)
            emit_sort_key_set(kept, place)
            e.emit_number(TMP, ((FLAGS + place) * 2) + 1)
            e.emit_branch(:b, answered)
            e.place_label(hidden)
            e.emit_number(TMP, (FLAGS + place) * 2)
            e.place_label(answered)
            e.emit_branch(:bl, marking)
          end

          # THE CODE EACH PLACE CALLS, at +label+, with TMP its answer: the offset of its flag in the
          # block twice over, plus 1 where the place shows. One number, so a place sets one register
          # for the call. Back at once where the flag already says so; otherwise the flag turned over,
          # the count of places not showing moved by one, and CHANGED set. Touches ACC, SPARE and HIGH
          # besides.
          def emit_flag_marking(kept, label)
            e = @emitter
            same = e.gensym
            e.place_label(label)
            e.emit(ASM.and_imm(ACC, TMP, 1))                # 1 where it shows
            e.emit_number(SPARE, kept.block)
            e.emit(ASM.add_reg_lsr(TMP, SPARE, TMP, 1))     # where its flag is
            e.emit(ASM.ldrb_offset(HIGH, TMP, 0))
            e.emit(ASM.cmp_reg(HIGH, ACC))
            e.emit_branch(:bcond, same, cond: :eq)
            e.emit(ASM.strb_offset(ACC, TMP, 0))
            e.emit(ASM.str_offset(SPARE, SPARE, CHANGED)) # any number but nought
            e.emit(ASM.ldr_offset(HIGH, SPARE, HIDDEN))
            e.emit(ASM.cmp_imm(ACC, 0))
            e.emit(ASM.add_imm_cond(:eq, HIGH, HIGH, 1))
            e.emit(ASM.sub_imm_cond(:ne, HIGH, HIGH, 1))
            e.emit(ASM.str_offset(HIGH, SPARE, HIDDEN))
            e.place_label(same)
            e.emit(ASM.return)
          end

          # On to +hidden+ unless +showing+ is 1, each test of it branched on where it is a product of
          # tests (Backends::ShownWhen). A copy is asked, since a comparison made of it takes it in.
          def emit_branch_unless_showing(showing, hidden)
            shown = ShownWhen.of(showing.copy) { |part| @primitives.const_int(part) }
            unless shown
              return @expressions.emit_branch_when(Build.binop(:==, showing.copy, Build.int(1)), holds: false, to: hidden)
            end

            @expressions.emit_branch_when(Build.binop(:==, shown.flag, Build.int(1)), holds: false, to: hidden) if shown.flag
            shown.tests.each { |test| @expressions.emit_branch_when(test, holds: false, to: hidden) }
          end

          # The program's write of the number of +place+, where the sort makes it.
          def emit_sort_key_set(kept, place)
            write = kept.keys&.fetch(place, nil) or return

            @setting_sort_keys = true
            @lowering.statement(write)
          ensure
            @setting_sort_keys = false
          end

          # THE LIST MOVED ROUND, on a pass where a place came or went: copied aside, then the entries not
          # showing written back from the front in the order they stood, then the entries showing after
          # them in theirs. Lists::SORT_AT reads the copy, Lists::SORT_END writes the list, Lists::SORT_KEYS holds the block,
          # Lists::SORT_ITEM is the entry, Lists::SORT_FIRST counts.
          def emit_shown_partition(kept, info)
            e = @emitter
            e.emit(ASM.push(Lists::SORT_AT, Lists::SORT_END, Lists::SORT_KEYS, Lists::SORT_ITEM, Lists::SORT_FIRST))
            e.emit_number(Lists::SORT_KEYS, kept.block)
            e.emit_number(ACC, 0)
            e.emit(ASM.str_offset(ACC, Lists::SORT_KEYS, CHANGED))
            copy = e.gensym
            e.emit_number(Lists::SORT_AT, info[:base])
            e.emit_number(Lists::SORT_END, kept.spare)
            e.emit_number(Lists::SORT_FIRST, kept.count)
            e.place_label(copy)
            emit_load_element(info, Lists::SORT_ITEM, Lists::SORT_AT)
            emit_store_element(info, Lists::SORT_ITEM, Lists::SORT_END)
            e.emit(ASM.add_imm(Lists::SORT_AT, Lists::SORT_AT, info[:bytes]))
            e.emit(ASM.add_imm(Lists::SORT_END, Lists::SORT_END, info[:bytes]))
            e.emit(ASM.subs_imm(Lists::SORT_FIRST, Lists::SORT_FIRST, 1))
            e.emit_branch(:bcond, copy, cond: :ne)
            e.emit_number(Lists::SORT_END, info[:base])
            emit_partition_pass(kept, info, written: 0)
            emit_partition_pass(kept, info, written: 1)
            e.emit(ASM.pop(Lists::SORT_AT, Lists::SORT_END, Lists::SORT_KEYS, Lists::SORT_ITEM, Lists::SORT_FIRST))
          end

          # One pass over the copy, writing at Lists::SORT_END every entry whose flag is +written+.
          def emit_partition_pass(kept, info, written:)
            e = @emitter
            read = e.gensym
            passed = e.gensym
            e.emit_number(Lists::SORT_AT, kept.spare)
            e.emit_number(Lists::SORT_FIRST, kept.count)
            e.place_label(read)
            emit_load_element(info, Lists::SORT_ITEM, Lists::SORT_AT)
            e.emit(ASM.add_reg(ACC, Lists::SORT_KEYS, Lists::SORT_ITEM))
            e.emit(ASM.ldrb_offset(ACC, ACC, FLAGS))
            e.emit(ASM.cmp_imm(ACC, written))
            e.emit_branch(:bcond, passed, cond: :ne)
            emit_store_element(info, Lists::SORT_ITEM, Lists::SORT_END)
            e.emit(ASM.add_imm(Lists::SORT_END, Lists::SORT_END, info[:bytes]))
            e.place_label(passed)
            e.emit(ASM.add_imm(Lists::SORT_AT, Lists::SORT_AT, info[:bytes]))
            e.emit(ASM.subs_imm(Lists::SORT_FIRST, Lists::SORT_FIRST, 1))
            e.emit_branch(:bcond, read, cond: :ne)
          end
        end
      end
    end
  end
end
