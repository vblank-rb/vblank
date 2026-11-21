# frozen_string_literal: true

module VBlank
  class Builder
    # Sprites drawn in an order the game works out
    #
    # Usually which sprite is in front of which is settled when the game is built: the one declared
    # later is in front, unless a layer orders otherwise. A top-down game cannot live with that. It
    # draws whichever character stands lower on the screen in front. Walk round below something and
    # you are drawn over it, walk round above it and it is drawn over you, and the answer changes
    # every time two things pass each other. `draw_in_order` does this.
    #
    # ```ruby
    # draw_in_order hero, guard, guards        # whoever stands lower is in front
    # ```
    #--
    # HOW IT WORKS, which is the same on every backend because it is written in the program
    # itself. Before each frame is drawn a routine works out every thing's number and puts
    # the things in order in a list the program keeps — one sort, which each console writes in
    # its own code, starting from the order they were in last frame, so a frame where nobody
    # passed anybody is one compare a thing. The frame's objects are then drawn with that run
    # in the list's order. Things whose numbers are equal keep the order they were already
    # in, so two characters standing level do not flicker in front of each other.
    #
    # TAKING TURNS IN FRONT. Many console games draw their sprites in one order on one frame
    # and the other way round on the next, so where two overlap each shows half the time and
    # neither hides the other for good — a falling piece over the pile, two characters
    # standing on one spot. The console keeps one picture per pixel, and the sprite earlier in
    # its table wins; turning the table round every frame is how those games share the pixel.
    #
    #   draw_in_order a, b, c, take_turns: true     # a in front on the first frame, c on the next
    #   draw_in_order a, b, c, take_turns: :last    # c in front on the first frame, a on the next
    #
    # There is no sort for it. The run has two orders only, the list as named and the list
    # turned round, so both are worked out when the cartridge is built and each frame copies
    # one of them (#declare_turn_table). Sorting a run that turns round every frame would move
    # every thing past every other each time, which for a few dozen things is more than a
    # frame on some consoles; the copy is a step for each thing.
    #++
    module DrawOrder
      FRONTS = %i[highest lowest].freeze

      # What `take_turns:` takes, and which one named is in front on the first frame shown.
      TURN_STARTS = { true => :first, first: :first, last: :last }.freeze

      # One order the game declared: its number, counting from 1; the sprites and pools in
      # it; which end of the number is in front; how a thing's number is worked out; and,
      # for an order that takes turns, which one named starts in front (:first or :last).
      Order = Data.define(:number, :things, :front, :key, :turns) do
        def part(name) = Messages::MadeNames.make(:draw_order, number: number, part: name)
        def routine = part(:sort)
        def keys_list = part(:keys)
        def order_list = part(:order)
        def turn_var = part(:turn)
      end

      # Draws sprites, and the things of a pool, in an order worked out every frame.
      #
      # Each thing is given a number, and the one with the highest number is in front. By default
      # the number is the bottom of the thing's box, so whoever stands lower is in front. A block
      # gives another number for each thing, for a puff of smoke that starts a step nearer the
      # front and drops back once it is grown, or a thing in the air that is drawn over whatever
      # it flies across.
      #
      # ```ruby
      # draw_in_order hero, guard, guards
      # draw_in_order(hero, puffs) { |thing| thing.bottom + thing.lift }
      # ```
      #
      # The order is among the things named: each takes the place of the backmost of them, and
      # anything else keeps its own place in front of or behind the whole run. So the things of
      # one order are declared in one layer, and a sprite is in one order at most. One told
      # `put_in_layer` is drawn in the layer it is in now, and the order holds inside each.
      #
      # Many console games draw their sprites in one order on one frame and the other way round on
      # the next, so that where two overlap each shows half the time and neither hides the other
      # for good, such as a falling piece over the pile. `take_turns:` does that. Then there is no
      # number to work out: the things take turns in front, the list as named on one frame and
      # turned round on the next, a pool's things one by one.
      #
      # ```ruby
      # draw_in_order a, b, c, take_turns: true     # a in front on the first frame, c on the next
      # draw_in_order a, b, c, take_turns: :last    # c in front on the first frame, a on the next
      # ```
      #
      # * `things` - the sprites and pools to put in order.
      # * `front:` - `:highest` (the default) or `:lowest`: which number is in front.
      # * `take_turns:` - `false` (the default), or `true` or `:first` to put the first one named in
      #   front on the first frame shown, or `:last` for the last one named.
      def draw_in_order(*things, front: nil, take_turns: false, &key)
        things = things.flatten
        turns = turn_start!(take_turns, front, key)
        front ||= :highest
        refuse_unknown_front!(front)
        things.each { |thing| refuse_unorderable_thing!(thing) }
        refuse_mixed_in_front!(things)
        refuse_order_of_one!(things)
        refuse_thing_named_twice!(things)
        things.each { |thing| refuse_thing_in_two_orders!(thing) }
        refuse_order_split_by!(things, "layer", &:layer)
        refuse_order_split_by!(things, "scene", &:scene)

        from_block = !key.nil?
        key ||= ->(thing) { thing.bottom }
        refuse_mixed_key_kinds!(things, key, from_block: from_block) unless turns
        order = Order.new(number: draw_orders.length + 1, things: things, front: front, key: key, turns: turns)
        # A pool's things are ordered one by one, so each needs its number (see Pool#order_by).
        things.each { |thing| thing.order_by(key) if thing.is_a?(DSL::Pool) } unless turns
        draw_orders << order
        nil
      end

      private

      def draw_orders = @draw_orders ||= []

      # EVERY THING'S NUMBER MUST BE OF ONE KIND. The numbers are sorted as plain whole numbers,
      # and a number holding a fraction is kept multiplied up (2.5 with 16 bits of fraction is
      # 163840; see DSL::Fraction). So when the block gives one thing a fraction and another a
      # whole number, 2.5 sorts as 163840 against a 3, and the order is wrong with nothing said.
      # Two fractions of different bits are wrong the same way.
      #
      # It is refused rather than put right by multiplying the whole number up, which is what
      # `a < b` does when a fraction meets a whole number the game works out
      # (DSL::Scale#node_matching): the framework cannot tell whether a whole number counts whole
      # pixels or something finer, so the author says which, with `.to_i` or `.to_f`, and every
      # number the sort reads is one the game's own code wrote. Unlike `a < b`, a whole number
      # written in the block is refused too, so no number is ever changed on its way to the sort.
      #
      # With no block, the numbers are the bottoms of the boxes, and a pool whose places hold a
      # fraction has a bottom that holds one; the advice is then to give a block.
      #
      # Each thing's number is worked out once here to read its kind, and dropped; nothing is
      # changed, so an order whose numbers are all of one kind builds the same bytes. A block is
      # expected to work a number out and do nothing else: one that also wrote a statement would
      # have it written here too.
      def refuse_mixed_key_kinds!(things, key, from_block:)
        kinds = things.to_h { |thing| [thing, order_key_bits(thing, key)] }
        return if kinds.values.uniq.length == 1

        first, other = kinds.to_a.uniq(&:last).first(2)
        both_fractions = first.last && other.last
        raise ArgumentError,
              "draw_in_order found #{key_kind_words(first.last, both_fractions)} for " \
              "#{order_thing_name(first.first)} and #{key_kind_words(other.last, both_fractions)} for " \
              "#{order_thing_name(other.first)}. The order can compare numbers of one kind only. " \
              "#{mixed_key_kinds_advice(both_fractions, from_block)}"
      end

      # How many fraction bits +key+ gives +thing+'s number, or nil for a whole number.
      def order_key_bits(thing, key)
        return thing.order_key_fraction_bits(key) if thing.is_a?(DSL::Pool)

        answer = key.call(thing)
        answer.discard! if answer.is_a?(DSL::Value)
        DSL::Fraction.bits_of(answer)
      end

      def mixed_key_kinds_advice(both_fractions, from_block)
        unless from_block
          return "The numbers are the bottoms of the boxes. Give draw_in_order a block that gives " \
                 "every thing one kind of number, for example `{ |thing| thing.bottom.to_i }`."
        end
        return "Give every thing a fraction with the same bits, or use `.to_i` on both." if both_fractions

        "Give every thing the same kind of number: use `.to_i` on the fraction, or `.to_f` on the whole number."
      end

      def key_kind_words(bits, both_fractions)
        return "a whole number" unless bits

        both_fractions ? "a number with #{bits} bits of fraction" : "a number with a fraction"
      end

      # The objects of one thing in an order, back to front: a sprite's one, or one for each
      # thing a pool can hold at once.
      def order_objects_of(thing)
        thing.is_a?(DSL::Pool) ? thing.stacked_objects : [thing.object_node]
      end

      # The list a pool keeps its things' numbers in, for a pool whose copy works them out
      # (Pool#order_key_read_from_copy?): one number a place, from the start.
      def declare_pool_order_keys(order)
        order.things.each do |thing|
          next unless thing.is_a?(DSL::Pool) && thing.ordered? && !thing.order_key_read_from_copy?

          at_boot(Build.list_new(thing.stacked_list(:order_key), thing.capacity, full_of: 0))
        end
      end

      # The number each object of +order+ is ordered by, by the object's name: a sprite's
      # worked out from its handle, a pool object's from what the pool copied for its place
      # (Pool#order_key_at_place).
      def order_keys(order)
        order.things.flat_map do |thing|
          if thing.is_a?(DSL::Pool)
            thing.stacked_objects.each_with_index.map { |node, place| [node.name, thing.order_key_at_place(place)] }
          else
            [[thing.object_name, DSL::Value.node_for(order.key.call(thing))]]
          end
        end.to_h
      end

      # The objects of +order+ in the order the draw list holds them, which is what the order
      # list counts into — and not, in general, the order the game named them in.
      def run_objects(order) = (@draw_order_runs ||= {}).fetch(order.number) { object_names_in(order) }

      # PUT EACH ORDER'S OBJECTS SIDE BY SIDE IN THE FRAME'S DRAW LIST, where the backmost of
      # them was, and tell every frame which run is ordered and where its order is kept. The
      # run has to be unbroken: what is put in order is a run of the draw list, and anything
      # standing between two of its objects would be passed by them as they swap.
      def arrange_draw_orders(names)
        draw_orders.reduce(names) do |list, order|
          objects = object_names_in(order)
          ordered = list.select { |name| objects.include?(name) }
          (list - ordered).insert(list.index(ordered.first), *ordered)
        end
      end

      def object_names_in(order) = order.things.flat_map { |thing| order_objects_of(thing).map(&:name) }

      # What each frame's present-objects node is told about the orders, once the draw list
      # is settled: each run's objects as they stand in the list, and the list its order is
      # kept in.
      def draw_order_runs(names)
        draw_orders.map do |order|
          objects = object_names_in(order)
          run = names.select { |name| objects.include?(name) }
          (@draw_order_runs ||= {})[order.number] = run
          Build::DrawOrder.new(objects: run, order: order.order_list, permutation: true)
        end
      end

      # BUILD EACH ORDER'S ROUTINE AND RUN IT BEFORE EVERY FRAME IS DRAWN — after the pools
      # have copied their things into place, since a pool's numbers are copied with them, and
      # just before the objects are drawn, so the order is the one the positions now give.
      def finalize_draw_orders
        return if draw_orders.empty?

        draw_orders.each do |order|
          declare_order_lists(order)
          declare_pool_order_keys(order)
          @functions[order.routine] = proc {}
          push_container(Build.func(order.routine)) { order_sort_nodes(order).each { |node| record(node) } }
        end
        @present_nodes.each do |present|
          container = present.parent or next
          at = container.children.index(present)
          draw_orders.reverse_each do |order|
            call = Build.call(order.routine)
            container.children.insert(at, call)
            call.parent = container
          end
        end
      end

      # The order starts as declared — each object's place pushed in turn, a different number
      # each — and every number at nought.
      #
      # A place is kept in a byte while there are 128 or fewer, and in a half past that: a byte
      # reads back with its sign, so the 129th place, 128, would read as -128.
      def declare_order_lists(order)
        count = object_names_in(order).length
        index = order.part(:fill)
        ensure_var(index)
        at_boot(Build.list_new(order.order_list, count, width: count > 128 ? :half : :byte))
        at_boot(Build.repeat(Build.int(count), index, Build.list_push(order.order_list, Build.var_ref(index))))
        return declare_turn_table(order, count) if order.turns

        at_boot(Build.list_new(order.keys_list, count, full_of: 0))
      end

      # AN ORDER THAT TAKES TURNS HAS ONLY TWO ORDERS, so both are written into the cartridge
      # when it is built, one after the other in one table, and each frame copies one of them
      # into the order list whole. The list holds the run back to front, each object by its
      # place in the run (which is not, in general, the order the game named them in): the
      # first half of the table ends with the first one named, so it is in front, and the
      # second half is the first half turned round.
      #
      # The turn is where in the table this frame's copy starts: nought for the first half,
      # +count+ for the second. A console's own games do the same thing without a table — they
      # walk their sprites from one end of the list or the other, a step up or a step down —
      # and the copy is that walk: a read and a write for each thing, with nothing compared.
      # The table keeps its entries as wide as the list does, since a copy moves them as they are.
      def declare_turn_table(order, count)
        run = run_objects(order)
        last_in_front = object_names_in(order).map { |name| run.index(name) }
        at_boot(Build.table(order.part(:turns), last_in_front.reverse + last_in_front,
                            width: count > 128 ? :half : :byte, signed: false))
        ensure_var(order.turn_var)
        at_boot(Build.set(order.turn_var, Build.int(order.turns == :first ? 0 : count)))
      end

      # WORK OUT EVERY NUMBER, THEN SORT. The list holds the objects back to front, so the
      # one in front is last: for :highest the numbers rise along it. The sort is one statement
      # (IR list_sort), which each backend writes as a routine in its own machine's code, and
      # it is stable: it starts from last frame's order and moves a thing back only past a
      # number strictly beyond its own, so two level things keep their order, and a frame where
      # nobody passed anybody moves nothing.
      #
      # A THING NOT SHOWING IS PUT BEHIND EVERYTHING by the sort itself (IR ListSort's +shown+),
      # handed whether each thing shows, the value it is drawn by (its `active`,
      # Reference#objects_on_screen). Things not showing then stand at the back of the list, and one
      # that shows again comes in from there, behind any thing level with it, as if newly added: the
      # way a console's own games rebuild their sprite list each frame from what is showing. So a
      # console may sort and draw only the things showing, and an order of many declared with a few
      # showing costs about what the few do. A thing that never stops showing is handed as showing,
      # and an order of such things is sorted as before.
      def order_sort_nodes(order)
        return order_turn_nodes(order) if order.turns

        keys = order.keys_list
        by_name = without_common_addend(order_keys(order))
        numbers = run_objects(order).each_with_index.map do |name, i|
          Build.list_set(keys, Build.int(i), by_name.fetch(name))
        end
        shown = order_shown(order)
        shown = nil if shown.all? { |value| value.kind == :int && value.value == 1 }
        numbers + [Build.list_sort(order.order_list, by: keys, descending: order.front == :lowest, shown: shown)]
      end

      # Whether each object of +order+ shows, in the order the run holds them: a copy of the value it
      # is drawn by, since a node belongs to one statement, or 1 for one that always shows.
      def order_shown(order)
        by_name = order.things.flat_map { |thing| order_objects_of(thing) }.to_h { |node| [node.name, node.active] }
        run_objects(order).map do |name|
          active = by_name.fetch(name)
          always_shown?(active) ? Build.int(1) : active.copy
        end
      end

      # Whether +active+, an object's, is 1 on every pass: the number 1, or a variable every
      # statement of the program that changes it sets to 1.
      def always_shown?(active)
        return active.value == 1 if active.kind == :int
        return false unless active.kind == :var_ref

        (@variable_writes ||= variable_writes).fetch(active.name, []).all? do |write|
          write.kind == :set && write.value.kind == :int && write.value.value == 1
        end
      end

      # Every statement of the program that changes a variable, by the variable's name.
      def variable_writes
        @program.walk.each_with_object(Hash.new { |all, name| all[name] = [] }) do |node, writes|
          name = IR::LightScenes.written_var(node)
          writes[name] << node if name
        end
      end

      # THE SAME NUMBER ADDED TO EVERY THING'S NUMBER CHANGES NO ORDER, so it is left out. A box's
      # bottom is the thing's place, plus where the box starts in it, plus its height, and things of
      # one size have the same two: the order of their bottoms is the order of their places, and
      # each thing's number is then a copy of its place, where it was a sum worked out every frame.
      # The one order it is not is past the biggest number there is, where a sum turns round to the
      # smallest; a thing placed there is two billion pixels off the screen.
      #
      # +keys+ is each thing's number, by name, handed back with the numbers written in the
      # program that every one of them adds up to the same total made noughts, in place: each
      # sum stays in the tree, so the game's own number it was worked out from is still used
      # (Guardrails::Checks::OrphanedExpression), and a lowering leaves a nought added out.
      def without_common_addend(keys)
        sums = keys.values.map { |node| sums_of_written_numbers(node) }
        totals = sums.map { |each| each.sum { |sum| sum.rhs.value } }.uniq
        return keys unless totals.length == 1 && !totals.first.zero?

        sums.flatten.each { |sum| sum.replace_operand(sum.rhs, Build.int(0)) }
        keys
      end

      # The sums in +node+ that add a number written in the program to it, outermost first: none
      # for a node that is not such a sum.
      def sums_of_written_numbers(node)
        sums = []
        while node.kind == :binop && node.op == :+ && node.rhs.kind == :int
          sums << node
          node = node.lhs
        end
        sums
      end

      # This frame's order copied from the table (#declare_turn_table), and the turn moved to the
      # other half for the next frame.
      def order_turn_nodes(order)
        count = object_names_in(order).length
        turn = order.turn_var
        [Build.list_copy(order.order_list, table: order.part(:turns), at: Build.var_ref(turn), count: count),
         Build.set(turn, Build.binop(:-, Build.int(count), Build.var_ref(turn)))]
      end

      # Which one named starts in front for +take_turns+ (nil when the order does not take
      # turns), refusing a front or a number of the game's own beside it: the order is the
      # list as named, so there is no number for either to decide.
      def turn_start!(take_turns, front, key)
        return nil if take_turns == false || take_turns.nil?

        turns = TURN_STARTS.fetch(take_turns) do
          raise ArgumentError,
                "draw_in_order was given take_turns: #{take_turns.inspect}. It must be true, :first or :last. " \
                "It says which thing is in front on the first frame: :first is the first thing you named."
        end
        if key
          raise ArgumentError,
                "draw_in_order was given take_turns: and a block. With take_turns, the order is the list " \
                "you named, so a block has no number to decide. Remove the block or take_turns:."
        end
        if front
          raise ArgumentError,
                "draw_in_order was given take_turns: and front:. With take_turns, the things are in front " \
                "one frame each, so front: has nothing to decide. To choose which thing starts in front, " \
                "use take_turns: :first or take_turns: :last."
        end
        turns
      end

      def refuse_unknown_front!(front)
        return if FRONTS.include?(front)

        raise ArgumentError,
              "draw_in_order was given front: #{front.inspect}. It must be :highest or :lowest. " \
              "It says which number is in front: :highest puts the thing with the biggest number in front."
      end

      def refuse_unorderable_thing!(thing)
        if thing.is_a?(DSL::Sprite)
          raise ArgumentError,
                "draw_in_order needs screen :tiled. On a bitmap screen a sprite is painted into the " \
                "picture, so there is no order left to change. Declare the screen as `screen :tiled`."
        end
        if thing.is_a?(DSL::Pool)
          return if thing.spriteful?

          raise ArgumentError,
                "pool :#{thing.name} draws nothing itself, so draw_in_order has nothing of it to put in " \
                "order. Give the pool `image:`, `facing:` or `frames:`."
        end
        return if thing.is_a?(DSL::HardwareSprite)

        raise ArgumentError,
              "draw_in_order puts things in order, and each one must be a sprite or a pool. " \
              "#{thing.inspect} is not one. Give it the handle that `sprite` or `pool` gave back."
      end

      # SPRITES IN FRONT ARE ORDERED AMONG THEMSELVES ONLY. A sprite in front (`in_front: true`) is
      # drawn after every sprite not in front (Builder#move_front_sprites_last), because a console
      # that keeps a priority bit in each sprite — the Genesis: the sprite attribute's priority bit,
      # which puts it over the plane cells whose own bit is set (Sega's Genesis Software Manual, the
      # VDP's sprite attribute table; plutiedev, "Sprites") — shows the pixel of the sprite earlier in its link list first
      # and asks its priority only then. So an order of sprites all in front is a run among them,
      # each one over the cells in front whichever is in front of the other; an order that mixed the
      # two would have a sprite not in front passing one in front, which would then be behind the
      # cells in front where they overlap.
      def refuse_mixed_in_front!(things)
        front, behind = things.partition { |thing| thing.is_a?(DSL::HardwareSprite) && thing.object_node.in_front }
        return if front.empty? || behind.empty?

        raise ArgumentError,
              "draw_in_order was given #{order_thing_name(front.first)}, drawn in front (`in_front: true`), and " \
              "#{order_thing_name(behind.first)}, not drawn in front. A sprite in front is always in front of every " \
              "sprite not in front, so one order cannot hold both kinds. To fix this, give each kind a draw_in_order " \
              "of its own, or give all of them the same `in_front:`."
      end

      def refuse_order_of_one!(things)
        return if things.sum { |thing| order_objects_of(thing).length } >= 2

        raise ArgumentError,
              "draw_in_order needs two things or more to put in order, and it was given one. " \
              "Name every sprite that can pass in front of another."
      end

      def order_thing_name(thing)
        return "pool :#{thing.name}" if thing.is_a?(DSL::Pool)

        "sprite :#{thing.object_node.declared || thing.object_name}"
      end

      def refuse_thing_in_two_orders!(thing)
        return unless draw_orders.any? { |order| order.things.any? { |other| other.equal?(thing) } }

        raise ArgumentError,
              "#{order_thing_name(thing)} is in two draw_in_order calls. A thing can be in one order only, " \
              "because one number decides where it is drawn. Put everything that passes it in one draw_in_order."
      end

      # A thing named twice in one call would have two places in the order, and the console's
      # sprite table has one place for each sprite: the order's numbers would then point past the
      # end of the run.
      def refuse_thing_named_twice!(things)
        twice = things.find { |thing| things.count { |other| other.equal?(thing) } > 1 }
        return unless twice

        raise ArgumentError,
              "#{order_thing_name(twice)} is named twice in one draw_in_order. Each thing has one place " \
              "in the order. Name it once."
      end

      # Things in one order must agree about what the block reads of each one's first object — the
      # layer, or the scene — since the order is a run of the draw list and a run is in one place in it.
      def refuse_order_split_by!(things, word)
        seen = things.to_h { |thing| [thing, yield(order_objects_of(thing).first)] }
        return if seen.values.uniq.length <= 1

        said = seen.map { |thing, value| "#{order_thing_name(thing)} is in #{value ? "#{word} :#{value}" : "no #{word}"}" }
        raise ArgumentError,
              "draw_in_order puts in order the things of one #{word}. #{said.join(', and ')}. " \
              "Put them in one #{word}, or give each #{word} a draw_in_order of its own."
      end

    end
  end
end
