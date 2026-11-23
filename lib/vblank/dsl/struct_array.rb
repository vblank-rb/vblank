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
    # A console keeps a fixed number of things, so `Array.new` must say `capacity:`. A full Array
    # adds nothing on `<<`; to make room for a new one, `shift` the oldest first.
    class StructArray
      # The Array methods an Array of Structs answers.
      VERBS = %i[<< push append shift clear each reverse_each each_with_index delete_if reject! size length
                 count empty? any?].freeze

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
        drawing = turned_pictures(PlainRuby::StructSettings.drawing_of(kind))
        fields = kind.members.to_h { |member| [member, fraction_field?(member, declaration) ? 0.0 : 0] }
        name = builder.plain_array_list_name(*name_and_owner(owner, declaration))
        widths = PlainRuby::StructSettings.widths_of(kind)
        @pool = builder.pool(name, capacity: capacity, widths: widths, **drawing, **settings, **fields)
        @walked = walked_class(kind)
      end

      # The pool this Array is kept as.
      attr_reader :pool # :nodoc:

      # Adds a thing, made with the Struct's `new`, after the others. A full Array adds nothing.
      def <<(thing)
        refuse_other_thing!(thing)
        values = @kind.members.to_h do |member|
          value = thing[member]
          refuse_field_with_no_value!(member) if value.nil?
          [member, value]
        end
        @pool.spawn(**values)
        self
      end
      alias push <<
      alias append <<

      # Takes out the oldest thing, the one added first. An empty Array takes out nothing.
      def shift
        oldest = Value.new(@builder, IR::Build.var_ref(@pool.head_var))
        @pool.remove_at(oldest) if @pool.count > 0
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
        @pool.each { |instance| yield(walked(instance)) }
        self
      end

      # Runs the block once for each thing, newest first.
      def reverse_each
        @pool.each(newest_first: true) { |instance| yield(walked(instance)) }
        self
      end

      # Runs the block once for each thing, oldest first, with where it is in the walk, from 0.
      def each_with_index
        position = @builder.hidden_variable(:position)
        position.store!(0)
        @pool.each do |instance|
          yield(walked(instance), position)
          position.increase!(1)
        end
        self
      end

      # Takes out each thing the block's test holds for.
      def delete_if
        @pool.each do |instance|
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
        @pool.each do |instance|
          counted.increase!(1) if yield(walked(instance))
        end
        counted
      end

      # A test that holds while there are none.
      def empty? = size == 0

      # A test that holds while there is one or more.
      def any?(&block)
        return size > 0 unless block

        count(&block) > 0
      end

      def inspect = "an Array of #{@kind.name || 'Struct'} kept as pool :#{@pool.name}" # :nodoc:

      def method_missing(name, *, &) # :nodoc:
        return super unless [].respond_to?(name)

        PlainRuby::Steps.refuse_game_code!("`#{@local}` is an Array of #{@kind.name || 'Structs'} that game code " \
                                           "changes, so the game keeps it as a pool. It does not answer `#{name}`. " \
                                           "It answers #{VERBS.map { |verb| "`#{verb}`" }.join(', ')}.")
      end

      def respond_to_missing?(name, include_private = false) = ![].respond_to?(name) && super

      private

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
      def walked_class(kind)
        Class.new(kind) do
          include Thing
          kind.members.each do |member|
            define_method(:"#{member}=") { |value| self[member].store!(value) }
          end
        end
      end

      # +setting+ with each picture named turned (`VBlank.mirror(:fish_right)`) turned by the build,
      # in a Hash or a list at any depth.
      def turned_pictures(setting)
        case setting
        when Hash then setting.transform_values { |value| turned_pictures(value) }
        when Array then setting.map { |value| turned_pictures(value) }
        when Graphics::TurnedPicture
          setting.way == :mirrored ? @builder.mirror(setting.source) : @builder.upside_down(setting.source)
        else setting
        end
      end

      # The thing +instance+ is, as an object of the game's Struct.
      def walked(instance)
        thing = @walked.allocate
        thing.instance = instance
        @kind.members.each { |member| thing[member] = @pool.field_ref(member, instance.index) }
        thing
      end

      def fraction_field?(member, declaration)
        position = @kind.members.index(member)
        declaration.thing_fractions.any? { |field| field == member || field == position }
      end

      def refuse_other_thing!(thing)
        return if thing.is_a?(@kind)

        PlainRuby::Steps.refuse_game_code!("`#{@local}` keeps #{@kind.name || 'Structs'} as a pool, and this line " \
                                           "puts #{thing.inspect} into it. To fix this, put a " \
                                           "`#{@kind.name}.new(...)` into it.")
      end

      def refuse_field_with_no_value!(member)
        PlainRuby::Steps.refuse_game_code!("This line puts a #{@kind.name || 'Struct'} into `#{@local}` with no " \
                                           "value for `#{member}`. A field the game keeps must hold a number. To fix " \
                                           "this, give `#{member}` a number in `#{@kind.name}.new(...)`.")
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

          PlainRuby::Steps.refuse_game_code!("`#{local}` is an Array of Structs that game code changes, so the game " \
                                             "keeps it as a pool. A console keeps a fixed number of things, so the " \
                                             "build must know how many. To fix this, write `#{local} = " \
                                             "Array.new(capacity: 8)` with a whole number or a constant.")
        end
      end

      # One thing of an Array of Structs
      #
      # What a walk hands the block: the game's own Struct, with what one thing of a pool answers.
      module Thing
        # The pool's own handle on this thing.
        attr_accessor :instance # :nodoc:

        # Turns this thing to face a direction (Pool::Instance#face).
        def face(direction, showing: nil) = instance.face(direction, showing: showing).then { self }

        # Draws this thing with another list of colours (Pool::Instance#draw_with).
        def draw_with(which, showing: nil) = instance.draw_with(which, showing: showing).then { self }

        # Moves this thing, stopping at solid tiles (Pool::Instance#move).
        def move(direction_or_dx, dy = nil, by: 1) = instance.move(direction_or_dx, dy, by: by).then { self }

        # Whether this thing could step that way (Pool::Instance#can_move?).
        def can_move?(direction, by: 1) = instance.can_move?(direction, by: by)

        # Keeps this thing wholly on the screen (Pool::Instance#clamp_to_screen).
        def clamp_to_screen = instance.clamp_to_screen.then { self }

        # Whether this thing's box overlaps another's (Bounds#overlaps?).
        def overlaps?(other) = instance.overlaps?(other)

        # The edges of this thing's box (Pool::Instance#left and the rest).
        def left = instance.left
        def top = instance.top # :nodoc:
        def right = instance.right # :nodoc:
        def bottom = instance.bottom # :nodoc:

        # The screen-edge tests (Bounds).
        def off_screen? = instance.off_screen?
        def off_left? = instance.off_left? # :nodoc:
        def off_right? = instance.off_right? # :nodoc:
        def above_top? = instance.above_top? # :nodoc:
        def below_bottom? = instance.below_bottom? # :nodoc:

        # This thing's own slot in the pool (Pool::Instance#index).
        def index = instance.index
      end
    end
  end
end
