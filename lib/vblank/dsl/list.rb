# frozen_string_literal: true

module VBlank
  module DSL
    # A list of numbers the game changes
    #
    # `list :name, capacity: 256` hands this back: numbers in order, whose length changes as
    # the game plays, such as a snake's growing body or the shots on screen. It holds at most
    # `capacity` numbers, and its methods read like a Ruby array's.
    #
    # ```ruby
    # body = list :body, capacity: 256
    # body.push head          # add the newest at the end
    # body.shift              # drop the oldest
    # tail = body.first       # a number, read as the game plays
    # body.each { |cell| draw_rect_at cell, 40, 2, 2, :green }
    # ```
    #
    # The methods that change the list (#push, #pop, #shift, #[]=, #fill, #copy_from) run
    # where they are written, inside a loop or an `if` as any line does. The ones that read
    # it (#[], #length, #first, #last) give numbers, which add, compare and draw like any
    # other.
    #
    # An item is a number: nil, `true`, `false` or a test's answer put into a list is a
    # friendly error. Keep a test's answer as `test ? 1 : 0`.
    #--
    # A List is the collection peer of Value: where a Value stands for one number, a List
    # stands for a run of them. The ones that change it record a statement into the program at
    # the current point, just like the builder's other verbs, and return self so calls chain.
    # Nothing is committed to the program by a read alone.
    #
    # Values going in or coming out cross the one coercion boundary (Value.node_for):
    # an index or a pushed value may be a Value, a bare Integer, or a :symbol naming
    # a variable, and a read hands back a Value — so a list composes with the rest of
    # the expression DSL without the caller thinking about IR nodes.
    #++
    class List
      Build = IR::Build

      # A list can hold numbers that carry a fraction, the same as a variable can. It is
      # declared once, on the list — `list :speeds, capacity: 8, holds: 0.0` — and from then
      # on every value read out of it carries the scale and every value put in is checked
      # against it, so the game writes halves and quarters and never mentions the scale
      # again. Without it, many of something that needs a fraction — the positions of a
      # crowd, a speed per instance — means picking a scale and carrying it by hand, which
      # is the exact bookkeeping the fraction support exists to remove.
      #
      # @param builder [Builder] the build the operations record into
      # @param name [Symbol] the list's name (its handle in the program)
      # @param fraction_bits [Integer, nil] how much fraction its items carry, nil for whole
      def initialize(builder, name, fraction_bits: nil)
        @builder = builder
        @name = name
        @fraction_bits = fraction_bits
      end

      # The list's name.
      attr_reader :name

      # How much fraction this list's items carry, or nil if they are whole numbers.
      attr_reader :fraction_bits # :nodoc:

      # --- growing / shrinking: record a statement ---

      # Adds a number at the end of the list. `<<` does the same.
      #
      # ```ruby
      # shots << hero_x
      # ```
      def push(value)
        record(Build.list_push(@name, item_node(value, "hold")))
        self
      end
      alias << push

      # Drops the oldest item, the one at the front of the list.
      #
      # A list the game shifts keeps its items in a ring, whose room is rounded up to a power
      # of two, so give such a list a power-of-two capacity.
      def shift
        record(Build.list_drop(@name, from: :front))
        self
      end

      # Drops the newest item, the one at the back of the list.
      def pop
        record(Build.list_drop(@name, from: :back))
        self
      end

      # Puts `value` in the item at `index`, in place of what it held. The item must be there
      # already: push it first, or start the list full with `full_of:`.
      #
      # ```ruby
      # board[row * 8 + column] = 1
      # ```
      def []=(index, value)
        record(Build.list_set(@name, Value.node_for(index), item_node(value, "hold")))
        value
      end

      # Makes the list hold exactly `count` entries of `table`, from entry `at` on: the letter
      # a name is drawn with, a frame of an animation, a row of a level.
      #
      # It is one copy rather than an entry at a time, so it is much quicker than a loop that
      # copies each. The table and the list must keep entries of the same width and the same
      # kind of number.
      #
      # ```ruby
      # name.copy_from letters, at: which * 64, count: 64
      # ```
      #
      # * `at:` - the first entry to copy. The game may work it out as it plays, and it is held
      #   inside the table.
      # * `count:` - how many entries, as a number written in the game.
      #--
      # See Builder#copy_table_run.
      #++
      def copy_from(table, at:, count:)
        @builder.copy_table_run(self, table, at: at, count: count)
        self
      end

      # Sets every item the list holds to `value`, or the `count` items from `from` on:
      # clearing a box a game letters text into, or a row of a board.
      #
      # It is one step, so it is much quicker than a loop that sets each item. Each number may
      # be worked out as the game plays. A run must stay inside the items the list holds now. A
      # list the game also shifts cannot be filled.
      #
      # ```ruby
      # box.fill 0
      # box.fill 0xFF, from: row * 30, count: 30
      # ```
      #
      # * `from:` - the first item to set.
      # * `count:` - how many items to set.
      #--
      # The console sets the run a whole word at a time (see Builder#fill_list_run). Past the
      # items the list holds the interpreter stops with an error, where the console only holds
      # the run to the capacity.
      #++
      def fill(value, from: nil, count: nil)
        @builder.fill_list_run(self, item_node(value, "hold"), from: from, count: count)
        self
      end

      # --- reading: hand back a Value ---

      # The item at `index`, as a number, read as the game plays. The first item is at 0.
      #
      # ```ruby
      # draw_rect_at shots[i], 20, 2, 4, :white
      # ```
      def [](index)
        item_value(Build.list_get(@name, Value.node_for(index)))
      end

      # How many items the list holds now, as a number read as the game plays. It is a count, so
      # it is a whole number even in a list of fractions.
      #
      # ```ruby
      # body.shift if body.length > snake_length
      # ```
      def length
        whole_value(Build.list_len(@name))
      end

      # The first item, the oldest, as a number.
      def first
        self[0]
      end

      # The last item, the newest, as a number.
      def last
        self[length - 1]
      end

      # Runs the block once for each item, front to back, giving it the item as a number.
      #
      # The count is the list's length when the walk starts each time, so the walk follows the
      # list as the game changes it.
      #
      # ```ruby
      # body.each { |cell| draw_rect_at cell, 40, 2, 2, :green }
      # ```
      #--
      # Sugar over Builder#repeat.
      #++
      def each(&block)
        list = self # `repeat` runs its block in the builder's context; keep our ref
        @builder.repeat(length) { |index| block.call(list[index]) }
      end

      private

      # Attach a list statement (push/drop/set) at the current build point.
      def record(node)
        @builder.record_statement(node)
      end

      # Wrap a list value node (get/length) in a Value handle so it composes with the
      # expression DSL.
      def whole_value(node)
        Value.new(@builder, node)
      end

      # ...and the same for an item, which carries whatever fraction the list holds.
      def item_value(node)
        Value.new(@builder, node, fraction_bits: @fraction_bits,
                                  declaring: fraction_declaration_advice, mixing: mixed_kinds_advice)
      end

      # How to make this list hold fractions, for the error somebody gets when they put a
      # number with one into a list of whole numbers.
      def fraction_declaration_advice
        @fraction_declaration_advice ||= ->(other) { "add `holds: #{other}` where `list :#{@name}` is declared" }
      end

      # ...and how to say the other mismatch, where the number and the list are two kinds.
      # A list has no left and right side, so the wording a plain operator uses does not fit.
      def mixed_kinds_advice
        @mixed_kinds_advice ||= lambda { |list_holds_fraction|
          holds, given = if list_holds_fraction
                           ["numbers with a fraction", "a whole number the game works out"]
                         else
                           ["whole numbers", "a number with a fraction"]
                         end
          "`list :#{@name}` holds #{holds}, and this is #{given}. There is no way to tell " \
            "what it counts. Use `.to_f` on the whole number to give it a fraction, or " \
            "`.to_i` on the other one to drop its fraction."
        }
      end

      # A value on its way into the list, checked against what the list holds. The rules are
      # the ones a variable follows, and they live in {Scale} so there is one copy of them.
      def item_node(value, verb)
        refuse_numberless_item!(value)
        item_scale.node_matching(value, verb)
      end

      # A slot keeps a number and nothing else: no mark beside it says "this was nil" or
      # "this was a yes or no", as a game variable's does. So nil, true, false and a test's
      # answer would come back as some number that Ruby never gave, and they are refused here,
      # at the game's line, saying how to write the number instead.
      def refuse_numberless_item!(value)
        problem = numberless_item_problem(value)
        return unless problem

        raise ArgumentError, "`list :#{@name}` keeps numbers. #{problem}#{Messages::AuthorSource.at_author_line}"
      end

      def numberless_item_problem(value)
        if value.nil?
          "This item is nil, and a list item cannot be nil. Give the item a number, for example 0."
        elsif [true, false].include?(value) || value.is_a?(Condition)
          "This item is the answer to a test, true or false, and a list item cannot be true or false. " \
            "To keep the answer, write `test ? 1 : 0`. When you read the item, compare it with 1."
        elsif !(value.is_a?(Numeric) || value.is_a?(Symbol) || value.is_a?(Value) || value.is_a?(IR::Node))
          "This item is a #{value.class.name}, and a list item must be a number. Give the item a number."
        end
      end

      # What this list keeps, as something that can answer the alignment questions on its
      # own. Asked directly rather than through a throwaway Value, so pushing onto a list
      # does not look like an expression somebody built and dropped.
      def item_scale
        @item_scale ||= Scale.new(bits: @fraction_bits, declaring: fraction_declaration_advice, mixing: mixed_kinds_advice)
      end
    end
  end
end
