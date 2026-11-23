# frozen_string_literal: true

module VBlank
  module DSL
    # An Array of Structs
    #
    # Many things of one kind, each with fields, kept by the game as a pool (DSL::Pool) where game
    # code changes the Array.
    #
    # ```ruby
    # Spark = Struct.new(:x, :y, :vy) do
    #   drawn_as :spark
    # end
    # sparks = Array.new(capacity: 32)
    # game_loop do
    #   sparks.shift if sparks.size == 32
    #   sparks << Spark.new(hero_x, 0, 1.5)
    #   sparks.each { |s| s.y += s.vy }
    #   sparks.delete_if { |s| s.y > 160 }
    # end
    # ```
    #
    # A game never names this class: the build makes one where the Array is made, when game code
    # puts things made from a Struct into it (PlainRuby::Arrays.list_from_new). It answers the
    # Array methods below, as Ruby's Array does, and refuses the others by name.
    #
    # A walk hands its block an object of the game's own Struct, so the Struct's methods run on
    # it, and each field holds the pool's number for that thing: `s.y += s.vy` changes it where it
    # stands. It also answers what one thing of a pool answers (Pool::Instance): `face`,
    # `draw_with`, `move`, `overlaps?`, the edges and the screen-edge tests.
    #
    # A console keeps a fixed number of things, so `Array.new` must be given `capacity:`. Ruby grows a
    # full Array on `<<`, and a console cannot, so a full one stops the game naming it, as a full
    # Array of numbers does (a pool with `on_full: :stop`); to make room for a new one, `shift`
    # the oldest first.
    class StructArray
      # The Array methods an Array of Structs answers.
      VERBS = %i[<< push append shift clear each reverse_each each_with_index delete_if reject! sort! sort_by! reverse!
                 min max minmax size length count empty? any?].freeze

      # The settings `Array.new` takes for one: how many, and where it is kept.
      SETTINGS = %i[fast].freeze

      # The Array a declaration names (PlainRuby::Arrays::Declaration), with +given+ and the
      # settings `Array.new` was handed.
      #
      # +owner+ is what the line ran on: the game block's builder, or a part of the game whose
      # instance variable holds the Array (`@enemies = Array.new(capacity: 4)`), which names it
      # as that variable's would be named, `enemies_part_enemies`.
      def self.declare(owner, declaration, given, capacity, settings, block)
        classes = declaration.things.call
        refuse_not_structs!(declaration.local, classes)
        refuse_many_kinds!(declaration.local, classes)
        refuse_start!(declaration.local) unless given.empty? && block.nil?
        refuse_unknown_settings!(declaration.local, settings)
        refuse_no_capacity!(declaration.local, capacity)
        new(Builder.in_use, owner, declaration, classes.first, capacity, settings)
      end

      def initialize(builder, owner, declaration, kind, capacity, settings)
        @builder = builder
        @kind = kind
        @local = declaration.local
        drawing = PlainRuby::StructSettings.drawing_of(kind)
        layer = drawing[:layer]
        drawing = drawing.except(:layer)
        drawing = drawing.merge(facing: turned_facing(drawing[:facing])) if drawing[:facing]
        fields = kind.members.to_h { |member| [member, fraction_field?(member, declaration) ? 0.0 : 0] }
        name = builder.plain_array_list_name(*name_and_owner(owner, declaration))
        widths = PlainRuby::StructSettings.widths_of(kind)
        made = lambda do
          builder.declare_pool(name, fields, capacity: capacity, on_full: :stop, widths: widths, struct_fields: true,
                                             **drawing, **settings)
        end
        @pool = layer ? builder.layer(layer) { made.call } : made.call
        @pool.explain_kinds_with { |field| kind_advice(field) }
        @walked = walked_class(kind)
        @walks_open = 0
      end

      # The pool this Array is kept as.
      attr_reader :pool # :nodoc:

      # Adds a thing, made with the Struct's `new`, after the others. A full Array stops the game.
      def <<(thing)
        refuse_other_thing!(thing)
        values = @kind.members.to_h do |member|
          value = thing[member]
          refuse_field_with_no_value!(member) if value.nil?
          [member, value]
        end
        # A push that can run during a walk of this Array may need a slot the walk took a thing
        # out of: one written inside a walk, or in a routine that may be called from one, as for
        # #shift. In the `initialize` of a part made by game code that made this Array there, it is
        # made on the part's first pass alone (Builder#once_for_part), since the part is made once.
        during_walk = @walks_open.positive? || @builder.building_callable_routine?
        @builder.once_for_part(@pool.name) { @pool.spawn_with(values, during_walk: during_walk) }
        self
      end
      alias push <<
      alias append <<

      # Takes out the oldest thing, the one added first. An empty Array takes out nothing.
      #
      # Only a `shift` that can run during a walk of this Array looks past what the walk took out:
      # one written inside a walk, or in a routine that may be called from one.
      def shift
        @pool.remove_oldest(during_walk: @walks_open.positive? || @builder.building_callable_routine?)
        nil
      end

      # Takes out every thing.
      def clear
        @pool.each(&:remove)
        self
      end

      # Runs the block once for each thing, oldest first. A thing added during the walk is first
      # walked by the next one.
      def each
        walk { |instance| yield(walked(instance)) }
        self
      end

      # Runs the block once for each thing, newest first.
      def reverse_each
        walk(newest_first: true) { |instance| yield(walked(instance)) }
        self
      end

      # Runs the block once for each thing, oldest first, with where it is in the walk, from 0.
      def each_with_index
        position = @builder.hidden_variable(:position)
        position.store!(0)
        walk do |instance|
          yield(walked(instance), position)
          position.increase!(1)
        end
        self
      end

      # Takes out each thing the block's test holds for.
      def delete_if
        walk do |instance|
          instance.remove if yield(walked(instance))
        end
        self
      end
      alias reject! delete_if

      # How many things there are, as a number the game keeps.
      def size = @pool.count
      alias length size

      # How many things there are, as #size, or with a block how many the block's test holds for.
      def count(&block)
        return size unless block

        counted = @builder.hidden_variable(:counted)
        counted.store!(0)
        walk do |instance|
          counted.increase!(1) if yield(walked(instance))
        end
        counted
      end

      # Puts the things in order by one of their fields, the smallest first, `{ |s| s.y }`, or
      # the biggest first, `{ |s| -s.y }`, as Ruby's `sort_by!` does. An Array of fields sorts by
      # the first, and each field after it breaks the ties of those before: `{ |s| [s.y, -s.x] }`.
      # What changes is the order they are walked in, and so the order they are drawn in: the
      # one walked first is drawn in front. Things that are level keep the order they had.
      #
      # ```ruby
      # sparks.sort_by! { |s| -s.y }
      # ```
      #--
      # One routine for each line that sorts (Pool#declare_sort), so `rom.profile` names the line
      # and what it costs.
      #++
      def sort_by!(&block)
        refuse_sort_in_walk!
        probe = walked(Pool::Instance.new(@pool, Value.new(@builder, IR::Build.int(0))))
        sort_by_key!(SortOrder.key_from(probe, block) { |node| field_sorted_by(node) })
      end

      # Puts the things in the order +key+ (SortOrder::Key) gives, with the routine for +line+:
      # what `sort_by!` does with the key its block gives, and what a Struct's own order does.
      def sort_by_key!(key, line: SortOrder.author_line) # :nodoc:
        refuse_sort_in_walk!
        sort_routines.call(key, line)
        self
      end

      # Turns the things round. Written right after `sort_by!`, it makes that sort put the
      # biggest first, at no cost of its own.
      def reverse!
        sort_routines.reverse_last!(@local)
        self
      end

      # Puts the things in the order their Struct says with `<=>`, as Ruby's `sort!` does, at the
      # cost of `sort_by!` by the same fields.
      #
      # ```ruby
      # Enemy = Struct.new(:x, :y) do
      #   include Comparable
      #   def <=>(other) = y <=> other.y          # by y; `other.y <=> y` for the biggest first
      # end
      # enemies.sort!
      # ```
      #
      # The `<=>` must compare fields: one field against the other thing's same field, or an
      # Array of those, `[y, x] <=> [other.y, other.x]`, for ties. A comparing block,
      # `sort! { |a, b| b.y <=> a.y }`, sorts by itself instead, by the same rule. A Struct with no
      # `<=>` of its own is refused, naming `sort_by!`.
      def sort!(&block)
        sort_by_key!(order_of(block))
      end

      # The thing the Struct's `<=>` puts first, as Ruby's `min` hands it back: one walk, keeping
      # the first thing no other comes before. A comparing block orders by itself instead. On an
      # empty Array it holds no thing, as Ruby's nil, and as a test it is false: `if (m = s.min)`.
      #
      # ```ruby
      # nearest = enemies.min
      # ```
      def min(count = nil, &block)
        refuse_count!(:min, count) if count
        best_in_order(order_of(block), smallest: true)
      end

      # The thing the Struct's `<=>` puts last, as Ruby's `max`.
      def max(count = nil, &block)
        refuse_count!(:max, count) if count
        best_in_order(order_of(block), smallest: false)
      end

      # `[min, max]`, as Ruby's `minmax`: two walks.
      def minmax(&block) = [min(&block), max(&block)]

      # The order the Struct's `<=>` says, as a SortOrder::Key, read once while building
      # (#order_of).
      def own_order # :nodoc:
        @own_order ||= begin
          refuse_no_order! unless SortOrder.own_order?(@kind)
          order_of(->(one, other) { one <=> other })
        end
      end

      # The order a comparing +block+ says, or with none the Struct's own: the block is handed two
      # stand-in things, the first in slot 0 and the second in slot 1, and each pair of numbers its
      # answer compared must be one field read from both, whose sides say which way it sorts
      # (SortOrder.key_from_comparison). It runs once, while building, so a block that records
      # anything the game would do (a change, a sound) is refused: Ruby would do that on every
      # comparison.
      private def order_of(block)
        return own_order unless block

        first, second = [0, 1].map { |slot| walked(Pool::Instance.new(@pool, Value.new(@builder, IR::Build.int(slot)))) }
        mark = @builder.statement_mark
        answer = block.call(first, second)
        refuse_order_doing_something! if @builder.recorded_since?(mark)
        SortOrder.key_from_comparison(answer, kind_name) do |left, right|
          field = field_sorted_by(left)
          next nil unless field && field == field_sorted_by(right)

          slots = [left, right].map { |node| node.index.kind == :int ? node.index.value : nil }
          SortOrder::Field.new(name: field, descending: slots == [1, 0]) if [[0, 1], [1, 0]].include?(slots)
        end
      end

      private def refuse_order_doing_something!
        PlainRuby::Steps.refuse_game_code!("The `<=>` of #{kind_name}, or the block that compares its things, does more " \
                                           "than compare: it changes something. The game reads the order once, while " \
                                           "it builds, so the change would not happen on each comparison as in Ruby. " \
                                           "To fix this, compare fields only, and make the change outside.")
      end

      private def refuse_count!(verb, count)
        PlainRuby::Steps.refuse_game_code!("`#{verb}(#{count})` gives an Array of things, and the game keeps no room " \
                                           "for a new Array. To fix this, sort `#{@local}` with `sort!` and walk the " \
                                           "first #{count} with `each_with_index`.")
      end

      # Does +one+ come before +other+ in +key+'s order (the other way round with +smallest+
      # false)? A test the game makes, field by field: a field decides unless the two are level
      # on it, and the next field is asked then.
      def precedes(one, other, key, smallest: true) # :nodoc:
        field, *rest = key.fields
        a = one[field.name]
        b = other[field.name]
        first = field.descending == smallest ? a > b : a < b
        return first if rest.empty?

        first | ((a == b) & precedes(one, other, SortOrder::Key.new(fields: rest), smallest: smallest))
      end

      # How `==` on these things compares, as Ruby's lookup finds it: :order where Comparable's
      # stands in front of Struct#== and the Struct has a `<=>` of its own (level on the order's
      # fields), :same_thing where Comparable has only Object's `<=>` to ask (which is 0 for the
      # same object alone), or :fields, Struct's own.
      def equality # :nodoc:
        return :fields unless @kind.instance_method(:==).owner == Comparable

        SortOrder.own_order?(@kind) ? :order : :same_thing
      end

      # Thing#clamp. Ruby's stops with an error where +min+ comes after +max+, which the game
      # cannot know while building, so only one thing as both is taken: the answer is then that
      # thing where +thing+ comes before or after it, and +thing+ where they are level.
      def clamped(thing, min, max) # :nodoc:
        refuse_other_array!(min)
        refuse_other_array!(max)
        unless min.equal?(max)
          PlainRuby::Steps.refuse_game_code!("`clamp` on two different things stops Ruby with an error when the first " \
                                             "comes after the second, and the game cannot know that while it builds. " \
                                             "To fix this, test the order yourself with `<` and `>`, and pick the " \
                                             "thing in each case.")
        end
        slot = @builder.hidden_variable(:clamped)
        slot.store!(thing.slot)
        (thing < min).record_branch { slot.store!(min.slot) }
        (thing > max).record_branch { slot.store!(max.slot) }
        walked(Pool::Instance.new(@pool, slot)).tap { |kept| kept.own_slot = true }
      end

      # A thing of another Array, or anything that is not a thing, cannot be compared with one of
      # these: the order reads both from this Array's slots.
      def refuse_other_array!(other) # :nodoc:
        return if other.is_a?(Thing) && other.struct_array.equal?(self)

        PlainRuby::Steps.refuse_game_code!("This line compares a thing of `#{@local}` with #{other.is_a?(Thing) ? 'a thing of another Array' : 'something that is not one of its things'}. " \
                                           "The game compares things of one Array only. To fix this, compare their " \
                                           "fields: `a.y < b.y`.")
      end

      # One walk keeping the slot of the first thing that no later thing comes before, started at
      # the first thing, so no slot read is out of the Array. The thing it hands back is, as a
      # test, whether the Array held any thing: Ruby's answer for an empty Array is nil.
      private def best_in_order(key, smallest:)
        refuse_order_question_in_walk!
        found = @builder.hidden_variable(:found)
        any = size > 0
        @builder.consume_condition(any)
        found.store!(Value.new(@builder, any.node))
        best = @builder.hidden_variable(:best)
        best.store!(Value.new(@builder, IR::Build.var_ref(@pool.head_var)))
        leader = walked(Pool::Instance.new(@pool, best))
        each do |thing|
          precedes(thing, leader, key, smallest: smallest).record_branch { best.store!(thing.slot) }
        end
        leader.tap do |kept|
          kept.own_slot = true
          kept.found_flag = found
        end
      end

      private def refuse_order_question_in_walk!
        if @walks_open.positive?
          PlainRuby::Steps.refuse_game_code!("This line asks `#{@local}` for its smallest or biggest thing while a " \
                                             "walk of it is under way. To fix this, ask after the walk ends.")
        end
        return unless @builder.building_callable_routine?

        PlainRuby::Steps.refuse_game_code!("This line asks `#{@local}` for its smallest or biggest thing in a routine. " \
                                           "A walk of `#{@local}` can call the routine, and then the walk would lose " \
                                           "its place. To fix this, ask outside the routine, after the walk ends.")
      end

      private def refuse_no_order!
        PlainRuby::Steps.refuse_game_code!("`#{@local}` holds #{kind_name} things, which have no order of their own. " \
                                           "To fix this, sort by one of their fields with `sort_by!`: " \
                                           "`#{@local}.sort_by! { |s| s.y }`, or give #{kind_name} a `<=>` that " \
                                           "compares its fields.")
      end

      # `sort` and `sort_by` make a new Array, which a console has no room for: refused, naming the
      # `!` method.
      def sort(*) = SortOrder.refuse_new_array!(@local, :sort)
      def sort_by(*) = SortOrder.refuse_new_array!(@local, :sort_by) # :nodoc:

      # A test that holds while there are none.
      def empty? = size == 0

      # A test that holds while there is one or more.
      def any?(&block)
        return size > 0 unless block

        count(&block) > 0
      end

      # +thing+ given a name that held +current+ (PlainRuby::Writes.write): a thing whose slot is
      # a number of its own, set to +thing+'s, so the name stays on that thing when the walk that
      # handed it over moves on, as a Ruby name stays on its object. A name that holds such a
      # thing of this Array already keeps it, and takes the new slot.
      def kept(thing, current) # :nodoc:
        if current.is_a?(Thing) && current.own_slot? && current.struct_array.equal?(self) && current.found_flag.equal?(thing.found_flag)
          current.slot.store!(thing.slot)
          return current
        end

        slot = @builder.hidden_variable(:kept)
        slot.store!(thing.slot)
        walked(Pool::Instance.new(@pool, slot)).tap do |own|
          own.own_slot = true
          own.found_flag = thing.found_flag # what `min` or `max` found, as a test (Thing#found_flag)
        end
      end

      def inspect = "an Array of #{kind_name} kept as pool :#{@pool.name}" # :nodoc:

      def method_missing(name, *, &) # :nodoc:
        return super unless [].respond_to?(name)

        PlainRuby::Steps.refuse_game_code!("`#{@local}` is an Array of #{kind_name} that game code changes, so the " \
                                           "game keeps it in a fixed number of slots. It does not answer `#{name}`. " \
                                           "It answers #{VERBS.map { |verb| "`#{verb}`" }.join(', ')}.")
      end

      def respond_to_missing?(name, include_private = false) = ![].respond_to?(name) && super

      private

      # The routines that sort this Array, each relinking its walk order (Pool#declare_sort).
      def sort_routines
        @sort_routines ||= SortOrder::Routines.new(@builder, @pool.name) { |name, key| @pool.declare_sort(name, key) }
      end

      # The field whose list +node+ reads, or nil: what `sort_by!`'s block gave.
      def field_sorted_by(node)
        return nil unless node.kind == :list_get

        @kind.members.find { |member| @pool.field_list(member) == node.name }
      end

      # A sort in a walk of this Array, or in a routine a walk may call (as #shift asks), would
      # relink the chain the walk is following, and slots the walk took out but has not freed.
      def refuse_sort_in_walk!
        if @walks_open.positive?
          PlainRuby::Steps.refuse_game_code!("This line sorts `#{@local}` while a walk of it is under way, and the " \
                                             "walk would lose its place. To fix this, sort `#{@local}` after the " \
                                             "walk ends.")
        end
        return unless @builder.building_callable_routine?

        PlainRuby::Steps.refuse_game_code!("This line sorts `#{@local}` in a routine. A walk of `#{@local}` can call " \
                                           "the routine, and then the walk would lose its place. To fix this, sort " \
                                           "`#{@local}` outside the routine, after the walk ends.")
      end

      # The pool's walk, counted while its block is built, so a `shift` written in it is known to
      # run during a walk (#shift).
      def walk(newest_first: false, &block)
        @walks_open += 1
        @pool.each(newest_first: newest_first, &block)
      ensure
        @walks_open -= 1
      end

      # The pool's name and who holds it (Builder#plain_array_list_name): a local's from the
      # declaration, an instance variable's after the object, each object of a class its own.
      def name_and_owner(owner, declaration)
        at = declaration.declared_at
        return [declaration.name, Builder::ListOwner.new(owner: [:array, declaration.source], at: at)] if declaration.name

        label = :"@#{declaration.local}"
        [PlainRuby::InstanceVariables.variable_name(owner, label),
         Builder::ListOwner.new(owner: [:object, owner.object_id, label], at: at)]
      end

      # The class of what a walk hands its block: the game's Struct, with a thing's verbs, and
      # each field's writer storing into the pool's field. Game code writes into the field it
      # holds without calling the writer (PlainRuby::Writes), and a method in a file that is not
      # game code (`self.y += 2` in a Struct brought in with `require_relative`) calls it, so the
      # field changes either way.
      #
      # The Struct's own methods are read again as game code onto it (PlainRuby::StructMethods),
      # so one in a file VBlank never read as game code asks its tests as the game plays.
      def walked_class(kind)
        walked = Class.new(kind) { include Thing }
        # Written out as source: a method made from a block could be called only in the Ractor
        # that made it.
        kind.members.each do |member|
          walked.class_eval("def #{member}=(value); self[#{member.inspect}].store!(value); end", __FILE__, __LINE__)
        end
        # A member named as what a thing answers (`left`, `move`, `index`) is the member, as in Ruby.
        (kind.members & Thing.public_instance_methods).each do |member|
          walked.class_eval("def #{member} = self[#{member.inspect}]", __FILE__, __LINE__)
        end
        PlainRuby::StructMethods.define_on(walked, kind)
        walked
      end

      # The directions a thing faces and the pictures for each, those `drawn_as` leaves out made by
      # turning their opposite's: facing left is facing right mirrored, facing down is facing up
      # turned upside down, and the other way round. The build turns each picture, so a direction
      # left out costs no art.
      def turned_facing(facing)
        turns = { left: [:right, :mirror], right: [:left, :mirror], down: [:up, :upside_down], up: [:down, :upside_down] }
        turned = turns.filter_map do |direction, (opposite, turn)|
          next if facing.key?(direction) || !facing.key?(opposite)

          [direction, turned_pictures(facing[opposite], turn)]
        end
        facing.merge(turned.to_h)
      end

      # +pictures+, a picture's name or a list of them, each turned by +turn+, Builder#mirror or
      # Builder#upside_down.
      def turned_pictures(pictures, turn)
        return pictures.map { |picture| turned_pictures(picture, turn) } if pictures.is_a?(Array)

        turn == :mirror ? @builder.mirror(pictures) : @builder.upside_down(pictures)
      end

      # The thing +instance+ is, as an object of the game's Struct.
      def walked(instance)
        thing = @walked.allocate
        thing.pool_instance = instance
        thing.struct_array = self
        @kind.members.each { |member| thing[member] = @pool.field_ref(member, instance.index) }
        thing
      end

      def fraction_field?(member, declaration)
        position = @kind.members.index(member)
        declaration.thing_fractions.any? { |field| field == member || field == position }
      end

      def refuse_other_thing!(thing)
        return if thing.is_a?(@kind)

        PlainRuby::Steps.refuse_game_code!("`#{@local}` keeps things made with `#{kind_name}.new`, and this line " \
                                           "puts #{thing.inspect} into it. To fix this, put a " \
                                           "`#{kind_name}.new(...)` into it.")
      end

      def refuse_field_with_no_value!(member)
        PlainRuby::Steps.refuse_game_code!("This line puts a #{kind_name} into `#{@local}` with no value for " \
                                           "`#{member}`. A field the game keeps must hold a number. To fix this, " \
                                           "give `#{member}` a number in `#{kind_name}.new(...)`.")
      end

      # The Struct's name as the game wrote it.
      def kind_name = PlainRuby::StructSettings.name_of(@kind)

      # What a number of the wrong kind given to +field+ is told (Pool#explain_kinds_with). A field
      # holds fractions where the build sees one given to it, as an Array of numbers does, so the
      # fix is to let it see one.
      def kind_advice(field)
        seen = "write `.to_f` after the number this game gives `#{field}`, where a `#{kind_name}` is made or in a " \
               "walk, so the build can see that `#{field}` holds fractions"
        mixing = lambda do |holds_fraction|
          if holds_fraction
            "`#{field}` of `#{kind_name}` holds numbers with a fraction. This line gives it a whole number the game " \
              "works out, and there is no way to tell what it counts. To fix this, use `.to_f` on the whole number."
          else
            "`#{field}` of `#{kind_name}` holds whole numbers, since no line the build can see gives it a fraction. " \
              "This line gives it a number with a fraction. To fix this, use `.to_i` on that number, or #{seen}."
          end
        end
        { declaring: ->(_given) { seen }, mixing: mixing }
      end

      class << self
        private

        def refuse_not_structs!(local, classes)
          return if classes.all? { |kind| kind.is_a?(Class) && kind < Struct }

          kind = classes.find { |each_kind| !(each_kind.is_a?(Class) && each_kind < Struct) }
          fix = kind.is_a?(Class) && kind < Data ? "A `Data` thing cannot change its fields. Make it with `Struct.new`." : "Make it with `Struct.new`."
          PlainRuby::Steps.refuse_game_code!("`#{local}` holds things made from #{kind.inspect}, which is not a Struct. " \
                                             "An Array of things that game code changes holds Structs. To fix this: #{fix}")
        end

        def refuse_many_kinds!(local, classes)
          return if classes.one?

          PlainRuby::Steps.refuse_game_code!("`#{local}` holds things of #{classes.length} kinds: " \
                                             "#{classes.map(&:inspect).join(', ')}. An Array of things that game " \
                                             "code changes holds one kind. To fix this, keep each kind in an Array " \
                                             "of its own.")
        end

        def refuse_start!(local)
          PlainRuby::Steps.refuse_game_code!("`#{local}` is an Array of Structs, and `Array.new` gives it a size or " \
                                             "a start. It starts empty. To fix this, write `Array.new(capacity: 8)`, " \
                                             "then put each thing in with `<<`.")
        end

        def refuse_unknown_settings!(local, settings)
          unknown = settings.keys - SETTINGS
          return if unknown.empty?

          PlainRuby::Steps.refuse_game_code!("`Array.new` for `#{local}` does not take `#{unknown.first}:`. For an " \
                                             "Array of Structs it takes `capacity:` and `fast:`. A Struct's look and " \
                                             "its narrow fields go in its block: `drawn_as` and `narrow`.")
        end

        def refuse_no_capacity!(local, capacity)
          return if capacity.is_a?(Integer) && capacity.positive?

          PlainRuby::Steps.refuse_game_code!("`#{local}` is an Array of Structs that game code changes. A console " \
                                             "keeps a fixed number of things, so the build must know how many. To fix this, write `#{local} = " \
                                             "Array.new(capacity: 8)` with a whole number or a constant.")
        end
      end

      # One thing of an Array of Structs
      #
      # What a walk hands the block: the game's own Struct, with what one thing of a pool answers.
      #--
      # The names of the framework's own (#pool_instance, #struct_array, #slot and the rest) are
      # ones a game's Struct is unlikely to have as members, since a member of the same name as any
      # method here wins (StructArray#walked_class), as it would in Ruby.
      #++
      module Thing
        # The pool's own handle on this thing.
        attr_accessor :pool_instance # :nodoc:

        # The Array of Structs this thing is in.
        attr_accessor :struct_array # :nodoc:

        # Whether this thing's slot is a number of its own (StructArray#kept), not a walk's.
        attr_writer :own_slot # :nodoc:

        def own_slot? = @own_slot || false # :nodoc:

        # For a thing `min` or `max` handed back: the hidden yes or no of whether the Array held
        # any thing then. As a test the thing is that, as Ruby's nil answer for an empty Array is
        # false (PlainRuby::Steps.game_test?). nil for any other thing, which is always there.
        attr_accessor :found_flag # :nodoc:

        # Whether this thing is there, as a test the game makes (#found_flag); nil where it always is.
        def found_test = (found_flag != 0 if found_flag) # :nodoc:

        # A test that holds while every field of this thing equals the same field of +other+, as
        # Struct#== compares two Structs. Anything that is not a Struct with these fields is never
        # equal.
        #
        # A Struct that includes Comparable compares as Ruby's Comparable#== does instead: level
        # on every field of its order (`<=>` answering 0), whatever its other fields hold, or, with
        # no `<=>` of its own, the same thing only (StructArray#equality).
        def ==(other)
          return false unless other.is_a?(Struct) && other.members == members

          case struct_array.equality
          when :order then level_in_order(other)
          when :same_thing then equal?(other)
          else eql?(other)
          end
        end

        # A test that holds while every field of this thing equals the same field of +other+, as
        # Struct#eql? does, whatever `==` compares.
        def eql?(other)
          return false unless other.is_a?(Struct) && other.members == members

          members.map { |member| self[member] == other[member] }.reduce(:&)
        end

        # Ruby's Comparable, answered by the Struct's own order (StructArray#own_order) as tests
        # the game makes: whether this thing comes before +other+, after it, and so on.
        def <(other)
          struct_array.refuse_other_array!(other)
          struct_array.precedes(self, other, struct_array.own_order)
        end

        # Does this thing come after +other+?
        def >(other)
          struct_array.refuse_other_array!(other)
          struct_array.precedes(self, other, struct_array.own_order, smallest: false)
        end

        # Does this thing come before +other+, or level with it?
        def <=(other) = !(self > other)

        # Does this thing come after +other+, or level with it?
        def >=(other) = !(self < other)

        # Is this thing from +min+ to +max+ in the order, both included?
        def between?(min, max) = (self >= min) & (self <= max)

        # +min+ where this thing comes before it, +max+ where it comes after it, or this thing, as
        # Ruby's `clamp`: a thing kept as a name keeps one.
        def clamp(min, max) = struct_array.clamped(self, min, max)

        private def level_in_order(other)
          struct_array.own_order.fields.map { |field| self[field.name] == other[field.name] }.reduce(:&)
        end

        # A test that holds while +other+ is this very thing: the same slot of the same Array.
        def equal?(other)
          return true if super
          return false unless other.is_a?(Thing) && struct_array.equal?(other.struct_array)

          slot == other.slot
        end

        # Turns this thing to face a direction (Pool::Instance#face).
        def face(direction, showing: nil) = pool_instance.face(direction, showing: showing).then { self }

        # Draws this thing with another list of colours (Pool::Instance#draw_with).
        def draw_with(which, showing: nil) = pool_instance.draw_with(which, showing: showing).then { self }

        # Moves this thing, stopping at solid tiles (Pool::Instance#move).
        def move(direction_or_dx, dy = nil, by: 1) = pool_instance.move(direction_or_dx, dy, by: by).then { self }

        # Whether this thing could step that way (Pool::Instance#can_move?).
        def can_move?(direction, by: 1) = pool_instance.can_move?(direction, by: by)

        # Keeps this thing wholly on the screen (Pool::Instance#clamp_to_screen).
        def clamp_to_screen = pool_instance.clamp_to_screen.then { self }

        # Whether this thing's box overlaps another's (Bounds#overlaps?).
        def overlaps?(other) = pool_instance.overlaps?(other.is_a?(Thing) ? other.pool_instance : other)

        # The edges of this thing's box (Pool::Instance#left and the rest).
        def left = pool_instance.left
        def top = pool_instance.top # :nodoc:
        def right = pool_instance.right # :nodoc:
        def bottom = pool_instance.bottom # :nodoc:

        # The screen-edge tests (Bounds).
        def off_screen? = pool_instance.off_screen?
        def off_left? = pool_instance.off_left? # :nodoc:
        def off_right? = pool_instance.off_right? # :nodoc:
        def above_top? = pool_instance.above_top? # :nodoc:
        def below_bottom? = pool_instance.below_bottom? # :nodoc:

        # This thing's own slot in the pool (Pool::Instance#index).
        def slot = pool_instance.index
      end
    end
  end
end
