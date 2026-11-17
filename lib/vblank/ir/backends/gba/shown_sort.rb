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
          def emit_shown_marked(node, kept, info)
            node.shown.each_with_index do |showing, place|
              next emit_sort_key_set(kept, place) unless kept.asked.fetch(place)

              emit_place_marked(showing, place, kept)
            end
            unchanged = @emitter.gensym
            @emitter.emit_number(TMP, kept.block)
            @emitter.emit(ASM.ldr_offset(ACC, TMP, CHANGED))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, unchanged, cond: :eq)
            emit_shown_partition(kept, info)
            @emitter.place_label(unchanged)
          end

          def emit_place_marked(showing, place, kept)
            e = @emitter
            hidden = e.gensym
            marked = e.gensym
            emit_branch_unless_showing(showing, hidden)
            emit_sort_key_set(kept, place)
            emit_flag_turned(kept, place, marked, was: 0, step: -1)
            e.emit_branch(:b, marked)
            e.place_label(hidden)
            emit_flag_turned(kept, place, marked, was: 1, step: 1)
            e.place_label(marked)
          end

          # On to +marked+ unless the flag of +place+ is +was+; otherwise the flag turned over, the count
          # of places not showing moved by +step+, and CHANGED set.
          def emit_flag_turned(kept, place, marked, was:, step:)
            e = @emitter
            e.emit_number(TMP, kept.block)
            e.emit(ASM.ldrb_offset(ACC, TMP, FLAGS + place))
            e.emit(ASM.cmp_imm(ACC, was))
            e.emit_branch(:bcond, marked, cond: :ne)
            e.emit_number(ACC, 1 - was)
            e.emit(ASM.strb_offset(ACC, TMP, FLAGS + place))
            e.emit(ASM.str_offset(TMP, TMP, CHANGED)) # any number but nought
            e.emit(ASM.ldr_offset(ACC, TMP, HIDDEN))
            e.emit(step.positive? ? ASM.add_imm(ACC, ACC, 1) : ASM.sub_imm(ACC, ACC, 1))
            e.emit(ASM.str_offset(ACC, TMP, HIDDEN))
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
