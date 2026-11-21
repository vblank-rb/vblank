# frozen_string_literal: true

module VBlank
  module DSL
    # Numbers the game keeps and works out
    #
    # A number the game keeps as it plays is a variable: `hp = 10` in a game block, or
    # `var :hp, 10`, makes one. Reading a pool's field, a list's item or a table's entry gives
    # a number too, and so does arithmetic on any of these. Each works like a Ruby number:
    # add, multiply and compare it, and change a variable with `=`, `+=` and `-=`.
    #
    # ```ruby
    # center = paddle_y + PADDLE_HEIGHT / 2   # a new number, worked out each pass
    # if ball_y > center                      # a test, answered as the game plays
    #   paddle_y += 2
    # end
    # ```
    #
    # A number written with a decimal point (`speed = 1.5`) keeps a fraction. Whole numbers and
    # fractions mix where the meaning is plain: `speed + 1` is one faster. Where it is not, the
    # build stops and says which side to change with `to_i` or `to_f`.
    #
    # The methods ending in `!` (`clamp!`, `approach!`, `flip!`, `abs!`, `negate_abs!`,
    # `bounce!`) change the variable they are called on. The same words without the `!` give a
    # new number and leave the variable alone. A new number that is worked out and never used
    # is a friendly error, because the work it stands for does nothing.
    #--
    # A Value that names a variable can be mutated — set / add / sub / clamp /
    # approach — which records the matching statement into the program. An
    # expression Value has no variable behind it, so mutating one is a friendly
    # error.
    #
    # Each Value wraps an IR value node; comparisons and arithmetic just build
    # bigger nodes, so nothing is committed to the program until a Condition's
    # `if` (or a change to a variable) runs.
    #
    # Deliberately no `<=>` / Comparable: those demand a build-time -1/0/1, but a
    # Value's magnitude isn't known until the ROM runs — which is exactly why the
    # comparison operators return a Condition (a runtime test), not a Ruby boolean.
    # Comparable would also redefine < > == to derive from `<=>` and hand back
    # plain booleans, and a game's `if x > 5` would be decided while building, once, for good.
    #++
    class Value
      Build = IR::Build

      # The one coercion boundary. Turns any value operand into an IR value node, so
      # nothing but a value node ever reaches the IR: a Value contributes its node,
      # and everything else goes through Build.to_value_node (an Integer becomes a literal, a
      # Symbol a variable reference, a value node passes through, and anything that
      # can't be a value raises a plain-language error). Every collision point — the
      # operators below and the builder's verbs — funnels through here, so a Value
      # and its `:symbol` are interchangeable everywhere a value is expected.
      def self.node_for(operand) # :nodoc:
        operand.is_a?(Value) ? operand.node : Build.to_value_node(operand)
      end

      # The number this operand already has, or nil when the game works it out as it runs.
      # The sibling of #node_for, and the same idea: ask for the answer rather than for the
      # class, because "a number the author wrote" is not one Ruby type. A bare 5, a literal
      # already wrapped for the tree, and a handle standing for one are the same fact, and a
      # variable, an expression and a run-time handle are the other fact.
      #
      # Asking after the class instead gets the second group right and the first group wrong:
      # a literal that had already been wrapped answered "the game works it out" and took the
      # run-time path for nothing. The report and the reference call these two fixed and
      # worked out, so the code uses fixed too.
      #
      # A fraction's bits are not checked, because no handle a game holds is a fraction over a
      # literal: the one place that makes one is #coerce, whose handle is used up by the operator
      # it was made for. A verb that ever hands one back must check them here.
      def self.fixed_number(operand) # :nodoc:
        node = operand.is_a?(Value) ? operand.node : operand # :nodoc:
        return node if node.is_a?(Integer)

        node.value if node.is_a?(IR::Node) && node.kind == :int
      end

      # @param builder [Builder] the build the mutators record into
      # @param node [IR::Node] the value node this handle stands for
      # @param name [Symbol, nil] the variable name, if this handle names one
      # @param fraction_bits [Integer, nil] how many fraction bits it carries; nil for a
      #   plain whole number (see {Fraction} for what carrying a fraction means)
      # +declaring+ is how to tell somebody to declare this kind of thing with a fraction,
      # given the number they wrote. A variable and a list declare it differently, and the rules
      # for lining two scales up are otherwise the same — so the rules live here once and
      # only the advice changes.
      #
      # +bang_spelling+ is how the author would change the variable this was worked out from instead —
      # see #bang_spelling.
      #
      # +tracked+ is false for a number the framework built without being asked (see
      # .handed_to_block).
      def initialize(builder, node, name: nil, fraction_bits: nil, declaring: nil, mixing: nil,
                     names: nil, bang_spelling: nil, tracked: true)
        @builder = builder
        @node = node
        @name = name
        @bang_spelling = bang_spelling
        @scale = Scale.new(bits: fraction_bits, declaring: declaring, mixing: mixing, names: names)
        # Only an expression is tracked, and only an expression pays for the stack walk
        # that pins the author's line — a handle can never be the orphan this is for.
        return if handle? || !tracked || !@builder.respond_to?(:track_expression)

        @source = Messages::AuthorSource.author_source
        @builder.track_expression(self)
      end

      # A number the framework builds to hand to an author's block: the row a bend is working
      # out, the instance a pool's routine runs on. A block is free to ignore what it is
      # handed — a bend the same on every row, a routine with nothing to do with its
      # instance — and a number the author never asked for is not one the author threw away.
      # So it is not tracked as one (see Builder#track_expression), and every number the
      # block works out from it still is.
      #
      # Not a handle: it names no place the author may write to, and nothing here pretends
      # it does.
      def self.handed_to_block(builder, node) = new(builder, node, tracked: false) # :nodoc:

      # The IR value node behind this handle (a var_ref, an int, or a binop).
      attr_reader :node

      # Where the author built this expression ("hero.rb:42"), for the diagnostic that
      # reports one nobody kept. nil for a handle, which is never reported.
      attr_reader :source # :nodoc:

      # A hidden variable for a name nothing had set yet (see PlainRuby::Steps.promote).
      attr_accessor :unwritten # :nodoc:

      def note_made_with_no_var_line = @builder.note_variable_with_no_var_line(@name) # :nodoc:

      # Was this variable made by normal Ruby with no `var` line: a name given a number (`hp = 10`,
      # `@seed = 5` named by `game_variables`)?
      def made_with_no_var_line? = @builder.variable_with_no_var_line?(@name) # :nodoc:

      # Is this variable a number in Ruby's eyes, which a local given it copies
      # (PlainRuby::Steps.kept_answer)? One made with no `var` line is, and so is a hidden one
      # the build made for a number. One a `var` line or a verb made is a handle the game holds.
      def number_in_ruby? = made_with_no_var_line? || hidden? # :nodoc:

      # Is this a hidden variable, one the build made for a number the author never named
      # (Builder#hidden_variable)?
      def hidden? = @name.to_s.start_with?(Build::KEPT_VARIABLE_PREFIX) # :nodoc:

      # The kinds of node whose number no line of the game can change: a number written out, a
      # cartridge table's item, and arithmetic on them.
      FIXED_KINDS = %i[int table_get binop neg absolute clamped].freeze # :nodoc:

      # Can the number this stands for change as the game plays? Only a working-out of fixed
      # numbers cannot, and a local given one needs no copy.
      def changes_as_game_plays? = @node.walk.any? { |each_node| !FIXED_KINDS.include?(each_node.kind) } # :nodoc:

      # Mark this variable as scratch no save keeps (`game_variables ..., saved: false`).
      def note_unsaved = @builder.note_unsaved_variable(@name) # :nodoc:

      # The place this variable was made for (PlainRuby::Writes.keep_as_own): the object and the
      # label of an instance variable, a Hash or an Array and its key for a slot, or no object for
      # a place in VBlank's own files. An instance variable handed a slot's variable only holds it,
      # and a write there must not change the slot (PlainRuby::Writes.handed_only?).
      Holder = Data.define(:object, :label) do # :nodoc:
        # Is this a slot of a Hash or an Array (PlainRuby::Writes.claim_unheld)?
        def slot? = object.is_a?(Hash) || object.is_a?(Array)
      end

      # The object of a Holder that is a local a `var` line made (PlainRuby::Writes.keep_as_local).
      LOCAL_HOLDER = Ractor.make_shareable(Object.new) # :nodoc:

      attr_reader :holder # :nodoc:

      def note_holder(object, label) = @holder = Holder.new(object, label) # :nodoc:

      # The instance variables of parts this variable was handed to whole, as an argument, which
      # each own it too (PlainRuby::Writes.share_argument).
      def note_sharer(object, label) = (@sharers ||= []) << Holder.new(object, label) # :nodoc:

      # Was this variable made for +label+ of +object+, or handed to it to change? A place in
      # VBlank's own files names no object, and takes any variable made for a place but a local
      # as its own.
      def held_by?(object, label) # :nodoc:
        return !@holder.nil? && !@holder.object.equal?(LOCAL_HOLDER) if object.nil?

        [@holder, *@sharers].any? { |place| place && place.object.equal?(object) && place.label == label }
      end

      # The plain name this hidden variable was made for, by PlainRuby::Writes.promote or
      # PlainRuby::Steps.kept_answer, or nil. The build's note of a hidden one names it too.
      attr_reader :owner_name # :nodoc:

      def owner_name=(name) # :nodoc:
        @builder.record_hidden_variable_local(@name, name) if name && hidden?
        @owner_name = name
      end

      # This copy keeps a button read while setting up, for game code to read
      # (PlainRuby::Steps.kept_answer): noted for Guardrails::Checks::PressKeptFromSettingUp.
      def record_kept_button = @builder.record_kept_button(@owner_name) # :nodoc:

      # A game has no nil, and a number variable has no false. A name that can hold those as well
      # as a number keeps which it holds in a hidden variable beside it: NIL_HELD, FALSE_HELD or
      # TRUTHY_HELD. The number is read as it stands, so a nil reads as 0.
      NIL_HELD = 0 # :nodoc:
      FALSE_HELD = 1 # :nodoc:
      TRUTHY_HELD = 2 # :nodoc:

      attr_reader :truth # :nodoc:

      def keep_truth! = @truth = @builder.hidden_variable(:truth) # :nodoc:

      # A name given nothing yet starts as nil, and that start is one statement. If what it is
      # given turns out to be something made while building, no number is kept and it goes.
      # +zero_number+ sets the number to 0 as well, for a line that runs after the number may have
      # changed; at power-on it is 0 already.
      def start_truth_as_nil!(zero_number: false) # :nodoc:
        keep_truth!
        @truth_start_places = []
        if zero_number
          store!(0)
          @truth_start_places << @builder.last_statement_place
        end
        @truth.store!(NIL_HELD)
        @truth_start_places << @builder.last_statement_place
      end

      def forget_truth! # :nodoc:
        @truth_start_places&.each { |place| @builder.take_back_statement(*place) }
        @builder.forget_hidden_variable(@truth.name) if @truth
        @builder.forget_hidden_variable(@name)
        @truth = nil
      end

      # The number and what it counts as, as they are now, on a hidden pair.
      def hidden_copy_with_truth(why) # :nodoc:
        kept = @builder.hidden_variable(why, like: self)
        kept.keep_truth!
        kept.store!(self)
        kept.truth.store!(truth)
        kept
      end

      # The variable this handle names, or nil for an expression and for a place that has no
      # name of its own (a pool field, a list slot). For a message that wants to say which.
      attr_reader :name # :nodoc:

      # Whether this stands for a place that keeps a number, rather than being a working-out
      # of one. A handle names somewhere — a variable here, a pool field in {FieldRef} — so
      # writing one down and doing nothing else with it is ordinary: `hero.x` on its own
      # line is pointless but harmless. An EXPRESSION is a number worked out and handed
      # back, so building one and dropping it means the work was thrown away. That is the
      # difference the orphaned-expression guardrail turns on.
      def handle? # :nodoc:
        !@name.nil?
      end

      # A hidden variable holding this number as it is now, whatever changes it later.
      def hidden_copy(why = :copy) # :nodoc:
        return hidden_copy_with_truth(why) if truth

        kept = @builder.hidden_variable(why, like: self)
        kept.store!(self)
        kept.mark_boolean! if boolean?
        kept
      end

      # A hidden variable holding this number for one step that reads it back before the step
      # ends, shared with every such step of +why+ in the routine (Builder#step_variable). A number
      # that carries a truth, a fraction or a yes or no keeps a variable of its own (#hidden_copy),
      # since the shared one would take on what it carries for every step.
      def step_copy(why) # :nodoc:
        return hidden_copy(why) if truth || fraction? || boolean?

        @builder.step_variable(why).tap { |kept| kept.store!(self) }
      end

      # This number is used for nothing: Ruby took it as truthy (see PlainRuby::Steps.branch_test).
      def discard! = @builder.forget_expression(self) # :nodoc:

      # Is this a variable the game keeps as a yes or no? See Builder#var.
      def boolean? = handle? && @builder.boolean_variable?(@name) # :nodoc:

      # This variable holds a yes or no from now on.
      def mark_boolean! = @builder.remember_boolean_variable(@name) # :nodoc:

      # How many fraction bits this value carries, or nil if it is a plain whole number.
      def fraction_bits # :nodoc:
        @scale.bits
      end

      # Whether this value carries a fraction rather than being a plain whole number.
      def fraction? # :nodoc:
        @scale.fraction?
      end

      # The names this value holds, or nil where it holds plain numbers. A variable declared
      # with a name — `var :mode, :title` — keeps one of a set of them, and what is stored is
      # the number each name was given (see {NameSet}). Read by `call`, which turns "the name
      # this variable holds" into the routine of that name.
      def names = @scale.names # :nodoc:

      # The node for +other+ brought to this value's scale, or a friendly error saying why
      # it cannot be.
      def node_matching(other, verb) # :nodoc:
        @scale.node_matching(other, verb)
      end

      # --- arithmetic: build a bigger expression Value ---

      # The sum of this number and another: a number, a variable or a sum of them.
      #
      # A whole number added to a number holding a fraction is read as that many whole
      # steps: `speed + 1` is one faster.
      #
      # ```ruby
      # right = x + width
      # ```
      def +(other)
        same_scale_binop(:+, other)
      end

      # This number less another: a number, a variable or a sum of them.
      #
      # ```ruby
      # gap = target_x - x
      # ```
      def -(other)
        same_scale_binop(:-, other)
      end

      # The same number the other way round: `-speed` is as far backwards as `speed` is
      # forwards. A number holding a fraction keeps it.
      def -@
        scaled(Build.neg(@node), @scale.bits)
      end

      # This number times another.
      #
      # A number holding a fraction times a whole number keeps the fraction: twice as fast is
      # twice as fast. Two numbers holding a fraction multiply correctly as well, with no
      # overflow on the way.
      #
      # ```ruby
      # step = speed * 2
      # ```
      #--
      # A fraction times another fraction is the one that overflows on the way, so it becomes
      # the full-width multiply automatically; see Fraction for why that is the point of the
      # whole thing.
      #++
      def *(other)
        bits = Fraction.bits_of(other)
        if fraction? && bits
          same_scale!(bits, "multiply")
          return scaled(Build.mul_fix(@node, node_at_scale(other, bits), bits), bits)
        end

        scaled(Build.binop(:*, @node, node_at_scale(other, bits)), @scale.bits || bits)
      end

      # This number divided by another, with whole numbers cut toward zero (so -7 / 2 is -3).
      #
      # A number holding a fraction divided by a whole number keeps the fraction: half the
      # speed is half the speed. Dividing by a number that holds a fraction gives an answer
      # holding one. An answer too big to keep is held at the biggest number there is, so
      # dividing by a number very close to zero does not wrap round to a negative one.
      #
      # Dividing by a 0 written in the game is a friendly error, since it has no answer.
      #
      # ```ruby
      # height = 160 / distance
      # ```
      #--
      # Dividing by another fraction is the one that needs care, for the mirror of the reason
      # `*` does: two numbers multiplied up by the same amount divide that amount straight back
      # out, so the answer would come back a whole number. The framework widens the numerator
      # first to stop that, which is what Build.div_fix is; see Fraction.
      #++
      def /(other)
        refuse_zero_divisor!(:/, other)
        bits = Fraction.bits_of(other)
        if fraction? && bits
          same_scale!(bits, "divide")
          return scaled(Build.div_fix(@node, node_at_scale(other, bits), bits), bits)
        end
        return whole_over_fraction(other, bits) if bits

        scaled(Build.binop(:/, @node, node_at_scale(other, bits)), @scale.bits)
      end

      # A plain whole number divided by one that holds a fraction. The answer holds a
      # fraction — 160 over 2.5 is 64, and over 2.4 it is not a whole number at all — so
      # the numerator is widened twice over: once to give the answer its fraction, and once
      # to cancel the divisor's.
      def whole_over_fraction(other, bits) # :nodoc:
        Value.new(@builder, Build.div_fix(@node, node_of(other), bits * 2), fraction_bits: bits)
      end

      # What is left over after dividing this number by another, as Ruby means it, so
      # `-1 % 64` is 63.
      #
      # This is how a number wraps onto a range: an angle that stepped below zero comes back
      # near a full turn, and a map position off the left edge comes back against the right
      # one. Wrapping onto a range that is a power of two (64, 256, 512) costs one
      # instruction; any other range is a real division.
      #
      # ```ruby
      # angle = (angle + turn) % 256
      # ```
      def %(other)
        refuse_zero_divisor!(:%, other)
        scaled(Build.binop(:%, @node, node_at_scale(other, Fraction.bits_of(other))), @scale.bits)
      end

      # --- the bits themselves ---
      #
      # Anything a game reads from a real console is several numbers packed into one: a
      # map cell carries a tile number, two flip flags and a palette bank; a row of a
      # collision shape is one bit per pixel; a save file is flags all the way down. The
      # code that reads those is written in bit operations, not because somebody liked
      # them but because that is what the bits are — and dividing cannot stand in, since
      # a mask over two fields that are not next to each other has no arithmetic form at
      # all.
      #
      # `&` keeps the bits both sides have, `|` keeps the bits either side has, `^` keeps
      # the ones exactly one side has, and `~` turns every bit the other way (which is how
      # a flag is cleared: `flags & ~DOOR_OPEN`). `<<` and `>>` slide the bits along.
      #
      # A number written into the program may stand on the LEFT of `&`, `|` and `^`, which
      # Ruby arranges through #coerce. It may not on the left of a shift — Ruby insists on
      # a plain number to the right of one — and #to_int is what says so in plain words
      # when somebody writes `0x8000 >> col`.

      # The bits set in both this number and the other: how a part of a packed number is read.
      #
      # A number written in the game may stand on either side. Bit operations work on whole
      # numbers, so a number holding a fraction is refused until `to_i` drops it.
      #
      # ```ruby
      # door_open = (flags & DOOR) != 0
      # flags = flags & ~DOOR                 # clears the flag
      # ```
      def &(other)
        bitwise(:&, other)
      end

      # The bits set in either this number or the other: how a flag is set.
      #
      # ```ruby
      # flags |= DOOR
      # ```
      def |(other)
        bitwise(:|, other)
      end

      # The bits set in exactly one of this number and the other: how a flag is turned over.
      #
      # ```ruby
      # flags ^= LIGHT
      # ```
      def ^(other)
        bitwise(:^, other)
      end

      # This number's bits slid up by `places`, filling in with zeros. Each place up doubles
      # the number.
      #
      # The number of places must be from 0 to 31 where the game writes it. A number written in
      # the game cannot stand on the left of `<<`, so put the game's number there:
      # `(row >> bit) & 1`, not `1 << bit`.
      #
      # ```ruby
      # mask = bits << 4
      # ```
      #--
      # Going off the top end empties the number; see IR::Int32 for what a count past the end of
      # a number does.
      #++
      def <<(places)
        refuse_shift_past_width!(:<<, places)
        bitwise(:<<, places)
      end

      # This number's bits slid down by `places`, filling in with the sign, so a negative
      # number stays negative, as in Ruby.
      #
      # With a mask after it, it reads a part out of the middle of a packed number.
      #
      # ```ruby
      # bank = (cell >> 12) & 15
      # ```
      def >>(places)
        refuse_shift_past_width!(:>>, places)
        bitwise(:>>, places)
      end

      # This number with every bit turned the other way. With `&` it clears a flag.
      #
      # ```ruby
      # flags &= ~DOOR
      # ```
      def ~
        whole_numbers_only!(:~, nil)
        Value.new(@builder, Build.bit_not(@node))
      end

      # `.then` on a number, which Ruby will happily answer and a game must not. Every Ruby
      # object has `then`, so `(flags & DOOR).then { open_it }` would run the block while the
      # game is built and record `open_it` with no test around it: the door opens every frame.
      def then(*) # :nodoc:
        raise ArgumentError,
              "`.then` does not branch on a number. A number is not a yes or a no. To fix this, " \
              "compare it and write `if`: `if (flags & 4) != 0 ... end`.#{at_dsl_line}"
      end

      # Ruby asked for a plain number, and this is one the game works out.
      #
      # Ruby calls this when it wants a real Integer and was handed something else.
      # Without it the program stops with "no implicit conversion of VBlank::DSL::Value into
      # Integer", which names a class the author never wrote and says nothing about what
      # to do instead. The place it actually happens is a shift with the number on the
      # left: Ruby routes `& | ^` through #coerce and pointedly does not route `<<` and
      # `>>` that way, so the message names that case.
      def to_int # :nodoc:
        raise ArgumentError,
              "Ruby needs a plain whole number here, and this one is worked out as the " \
              "game runs. This usually happens on the right of `<<` or `>>`, so " \
              "`1 << bit` and `0x8000 >> bit` do not work. Put the value on the left " \
              "instead — `(row >> bit) & 1` reads one bit, and `bit` can still be " \
              "worked out as the game runs.#{at_dsl_line}"
      end

      # Let a plain number stand on the LEFT of an operator: `160 / distance` is how a
      # person writes a wall height, and Ruby asks the value on the right how to make sense
      # of that. A number written here takes this value's own kind, so dividing by
      # something holding a fraction gives an answer holding one.
      def coerce(other) # :nodoc:
        bits = other.is_a?(Float) ? (@scale.bits || Fraction::DEFAULT_BITS) : nil
        literal = bits ? Fraction.scale(other, bits) : other
        [Value.new(@builder, Build.int(literal), fraction_bits: bits), self]
      end

      # --- moving between a fraction and a whole number ---

      # This number as a whole number, with its fraction dropped. It rounds down, so -0.5
      # becomes -1.
      #
      # This is what a position on the screen or an item's number wants. It costs one
      # instruction, not a divide. A whole number comes back as it is.
      #
      # ```ruby
      # column = px.to_i / 8
      # ```
      #--
      # See IR::Int32.shift_right.
      #++
      def to_i
        return self unless fraction?

        Value.new(@builder, Build.shift_right(@node, @scale.bits))
      end

      # This whole number as one that holds a fraction, so it can be added to one or compared
      # with one. A number that already holds a fraction comes back as it is.
      #
      # ```ruby
      # px = hero_x.to_f + drift
      # ```
      def to_f
        return self if fraction?

        bits = Fraction::DEFAULT_BITS
        scaled(Build.binop(:*, @node, Build.int(1 << bits)), bits)
      end

      # The product of two whole numbers that each stand for a fraction multiplied up by
      # `2 ** fraction_bits`, kept the same way, with no overflow on the way.
      #
      # This is for numbers a game keeps multiplied up by hand. A number written with a
      # decimal point keeps its fraction for itself, and plain `*` multiplies two of those
      # correctly, so most games never need this.
      #
      # ```ruby
      # speed = var :speed, (3 * 65536) / 2                       # 1.5, with 16 fraction bits
      # step  = speed.times_fraction(speed, fraction_bits: 16)    # 2.25, kept the same way
      # ```
      #
      # * `fraction_bits:` - how many of the low bits hold the fraction, on both sides and in
      #   the answer.
      #--
      # A variable holds whole numbers only, so a program that needs halves and
      # quarters keeps its numbers multiplied up by a fixed amount and remembers to
      # divide back at the end. `fraction_bits: 16` means "multiplied up by 2**16", so
      # 1.5 is stored as 98304. Adding and subtracting those works as it is. Times
      # does not: two multiplied-up numbers multiply out to a number multiplied up
      # twice, and that intermediate is usually far too big for a variable to hold —
      # 1.5 times 1.5 needs 6,442,450,944 on the way. Plain `*` loses the top of it
      # and the answer is nonsense.
      #
      #   speed = var :speed, (3 * 65536) / 2     # 1.5, with 16 fraction bits
      #   step  = speed.times_fraction(speed, fraction_bits: 16)   # 2.25, kept the same way
      #
      # Both sides must carry the same number of fraction bits, and so does the answer.
      #
      # Nothing checks that for you: you give the number of bits at each multiply, and
      # the framework has no idea which of your variables hold fractions. That is a
      # deliberate stopping point rather than an oversight. The alternative is for the
      # scale to travel with the value, so `a * b` does the right thing because the
      # compiler knows what a and b are and mixing scales is a build error — much
      # closer to what this framework promises, and much more machinery (a type on
      # every Value, inference through every operation, conversions at every boundary
      # where a fraction meets a pixel coordinate). It is worth designing from real
      # call sites that turned out annoying, not from first principles, and there are
      # none yet — this is the first thing that can even express the arithmetic.
      #++
      def times_fraction(other, fraction_bits:)
        Value.new(@builder, Build.mul_fix(@node, node_of(other), fraction_bits))
      end

      # --- comparisons: build a Condition ---

      # A test that holds while this number is more than the other.
      #
      # A test is answered as the game plays, so it goes after `if`, `unless`, `while` or
      # `until` (see Condition).
      #
      # ```ruby
      # x = 0 if x > 239
      # ```
      def >(other)
        compare(:>, other)
      end

      # A test that holds while this number is less than the other.
      #
      # ```ruby
      # lives -= 1 if hp < 1
      # ```
      def <(other)
        compare(:<, other)
      end

      # A test that holds while this number is the other or more.
      def >=(other)
        compare(:>=, other)
      end

      # A test that holds while this number is the other or less.
      def <=(other)
        compare(:<=, other)
      end

      # A test that holds while this number is the same as the other. A variable that keeps a
      # name compares with the name: `mode == :title`.
      def ==(other)
        compare(:==, other)
      end

      # A test that holds while this number is not the same as the other.
      def !=(other)
        compare(:!=, other)
      end

      # A test that holds while this number is 0, as Ruby asks it: `if lives.zero?`. It costs
      # what `lives == 0` costs.
      def zero? = compare(:==, 0)

      # A test that holds while this number is more than 0. It costs what `n > 0` costs.
      def positive? = compare(:>, 0)

      # A test that holds while this number is less than 0. It costs what `n < 0` costs.
      def negative? = compare(:<, 0)

      # The number questions Ruby has that a game's numbers do not answer here. Asking one is
      # refused in plain words with the comparison to write, rather than with Ruby's own
      # "undefined method", which names a class of the library's and nothing a game wrote.
      NUMBER_QUESTIONS_INSTEAD = { # :nodoc:
        nonzero?: "!= 0", even?: "% 2 == 0", odd?: "% 2 != 0", finite?: nil, infinite?: nil,
        integer?: nil
      }.freeze

      def method_missing(name, *args, &) # :nodoc:
        return super unless NUMBER_QUESTIONS_INSTEAD.key?(name) || (name.end_with?("?") && 0.respond_to?(name))

        instead = NUMBER_QUESTIONS_INSTEAD[name]
        written = @name ? name_as_written : "the number"
        fix = instead ? " Write the comparison instead: `#{written} #{instead}`." : ""
        raise ArgumentError,
              "A game's number does not answer `#{name}`. It answers `zero?`, `positive?` and " \
              "`negative?`, and the comparisons `==`, `!=`, `<`, `<=`, `>` and `>=`.#{fix}#{at_dsl_line}"
      end

      def respond_to_missing?(name, include_private = false) # :nodoc:
        return false if NUMBER_QUESTIONS_INSTEAD.key?(name) || (name.end_with?("?") && 0.respond_to?(name))

        super
      end

      # --- mutation: record a statement (variable handles only) ---

      # A number worked out on the spot is not somewhere a value can be kept, so neither a
      # changing word nor its `!` form has anything to change.
      NOT_A_VARIABLE = "only a variable can be changed (one from `var :name`), not an " \
                       "expression — assign the expression to a variable first" # :nodoc:

      # Assign a new value: a number, another variable, or an expression Value. A variable
      # that holds a fraction takes one, and a number written here is converted to match.
      def store!(value) # :nodoc:
        mutate { @builder.store!(@name, align!(value, "assign")) }
      end

      # Add to the variable (a number or another Value).
      def increase!(amount) # :nodoc:
        mutate { @builder.increase!(@name, align!(amount, "add")) }
      end

      # Subtract from the variable (a number or another Value).
      def decrease!(amount) # :nodoc:
        mutate { @builder.decrease!(@name, align!(amount, "subtract")) }
      end

      # Holds the variable from `lo` to `hi`: below `lo` it becomes `lo`, above `hi` it
      # becomes `hi`.
      #
      # Both ends may be numbers written in the game or numbers it works out as it plays. A
      # `lo` worked out to more than `hi` gives `hi`.
      #
      # ```ruby
      # x.clamp!(0, 232)
      # speed.clamp!(0, top_speed)
      # ```
      def clamp!(lo, hi)
        mutate { @builder.clamp_variable!(@name, operand_matching(lo, "compare"), operand_matching(hi, "compare")) }
      end

      # Moves the variable toward `target` by at most `step`, and never past it: a chase at a
      # top speed, or an ease toward a resting place.
      #
      # A step written in the game must be more than 0. A step the game works out is read as a
      # distance, so a negative one still moves toward the target and 0 holds still.
      #
      # ```ruby
      # camera_x.approach!(hero_x - 120, 4)
      # ```
      #--
      # See Builder#approach_variable!.
      #++
      def approach!(target, step)
        mutate { @builder.approach_variable!(@name, operand_matching(target, "compare"), operand_matching(step, "add")) }
      end

      # Turns `velocity` round when this number is at either end of `range`: a ball coming back
      # off a wall.
      #
      # At or below the low end the velocity is made positive, and at or above the high end it
      # is made negative. Only the velocity changes. This number stays where it is, so a ball a
      # little past the wall is still there next pass, and still turned the right way: the
      # velocity is set to point away from the wall rather than flipped, so a second pass on
      # the wall cannot send it back in. Hold the number with #clamp! first if that matters.
      #
      # The block, if there is one, runs at each turn, once for the end that was hit. It is the
      # two tests a game would write itself, and so it costs what they cost.
      #
      # ```ruby
      # x.bounce!(dx, 0..right) { beep :click }
      # ball.x.bounce!(ball.dx, 0..232)
      # ```
      #
      # * `velocity` - the variable or pool field that holds the speed.
      # * `range` - the two walls, written with two dots so the high end is in it. Either end
      #   may be a number the game works out.
      def bounce!(velocity, range, &on_turn)
        refuse_bounce_velocity!(velocity)
        refuse_bounce_range!(range)

        (self <= range.begin).record_branch do
          velocity.abs!
          on_turn&.call
        end
        (self >= range.end).record_branch do
          velocity.negate_abs!
          on_turn&.call
        end
        self
      end

      # Makes the variable its distance from 0: a negative number turns positive.
      #
      # ```ruby
      # dy.abs! if y <= 0     # off the ceiling, heading down
      # ```
      def abs!
        mutate { @builder.absolute_variable!(@name) }
      end

      # Makes the variable negative, or 0: it becomes minus its distance from 0.
      #
      # ```ruby
      # dy.negate_abs! if y >= FLOOR   # off the floor, heading up
      # ```
      def negate_abs!
        mutate { @builder.negate_absolute_variable!(@name) }
      end

      # Turns the variable the other way round: 3 becomes -3 and -3 becomes 3.
      #
      # ```ruby
      # dx.flip! if x > 232
      # ```
      def flip!
        mutate { @builder.negate_variable!(@name) }
      end

      # --- the same five as new numbers ---
      #
      # Each is the number its `!` form would store.

      # This number's distance from 0, as a new number: `d.abs <= 5` asks whether `d` is
      # within 5 either way.
      #
      # ```ruby
      # close = (enemy_x - hero_x).abs < 16
      # ```
      def abs = new_number(Build.absolute(@node), "abs!")

      # This number held from `lo` to `hi`, as a new number to compare or keep. #clamp! tells
      # the rules.
      #
      # ```ruby
      # column = (x / 8).clamp(0, 29)
      # ```
      def clamp(lo, hi)
        new_number(Build.clamped(@node, operand_matching(lo, "compare"), operand_matching(hi, "compare")), "clamp!")
      end

      # Where this number would be one step toward `target`, as a new number: moved by at most
      # `step`, and never past it. #approach! tells the rules for the step.
      #
      # ```ruby
      # next_x = x.approach(goal_x, 2)
      # ```
      def approach(target, step)
        step = operand_matching(step, "add")
        fixed = Value.fixed_number(step)
        raise ArgumentError, "approach's step must be positive. You gave #{fixed}." if fixed && !fixed.positive?

        distance = fixed || Build.absolute(step)
        low = fixed ? -fixed : Build.neg(distance)
        gap = Build.binop(:-, operand_matching(target, "compare"), @node)
        new_number(Build.binop(:+, @node, Build.clamped(gap, low, distance)), "approach!")
      end

      # This number the other way round, as a new number: the same as `-x`.
      def flip = new_number(Build.neg(@node), "flip!")

      # Minus this number's distance from 0, as a new number: never more than 0.
      def negate_abs = new_number(Build.neg(Build.absolute(@node)), "negate_abs!")

      # How to change the thing this names instead of making a new number, for the message
      # about a new number nobody kept — "d.abs!" for a variable. Nil for a new number that
      # was not made by one of the five words above straight from a variable or a pool field.
      attr_reader :bang_spelling # :nodoc:

      private

      # The velocity is changed, so it must name somewhere a number is kept: a variable, or a
      # field of a pool's thing.
      def refuse_bounce_velocity!(velocity)
        return if velocity.is_a?(Value) && velocity.handle?

        raise ArgumentError,
              "`bounce!` must have a variable for the speed, because it changes the speed at a wall. " \
              "You gave #{Messages::PlainWords.words_for_given(velocity)}. " \
              "Give the variable that holds the speed, for example `x.bounce!(dx, 0..right)`.#{at_dsl_line}"
      end

      # A range with both ends, and its high end in it. `0...100` stops short of 100, and a
      # number with a fraction can sit between 99 and 100, so there is no one number to turn at.
      def refuse_bounce_range!(range)
        given = Messages::PlainWords.words_for_given(range)
        unless range.is_a?(Range) && !range.begin.nil? && !range.end.nil?
          raise ArgumentError,
                "`bounce!` must have a range with a low end and a high end, for example `0..right`. " \
                "You gave #{given}.#{at_dsl_line}"
        end
        return unless range.exclude_end?

        raise ArgumentError,
              "`bounce!` must have a range that includes its high end. `#{given}` stops before its high end. " \
              "Write two dots: `#{given.sub('...', '..')}`.#{at_dsl_line}"
      end

      def compare(op, other)
        Condition.new(@builder, Build.binop(op, @node, align!(other, describe_op(op))))
      end

      # A bit operation. Both sides are plain whole numbers — no scale to line up, since
      # the answer is about the bits and not about what they add up to.
      def bitwise(op, other)
        whole_numbers_only!(op, other)
        Value.new(@builder, Build.binop(op, @node, node_of(other)))
      end

      # A count written into the program that moves every bit off the end. The number is
      # right there to read, so this is a mistake the build can see, and it is always a
      # mistake: the answer no longer depends on what was shifted, and somebody who
      # wanted nothing would have written nothing.
      #
      # A count the game works out is left alone. That one comes out of data and can land
      # anywhere, which is exactly why IR::Int32 pins what happens when it lands outside.
      def refuse_shift_past_width!(op, places)
        count = Value.fixed_number(places)
        return if count.nil? || IR::Int32.shift_count_in_range?(count)

        advice =
          if count.negative?
            "A shift count cannot go below 0. To move the bits the other way, use " \
              "`#{op == :<< ? '>>' : '<<'}`."
          else
            "Write a count from 0 to 31."
          end
        raise ArgumentError,
              "`#{op} #{count}` moves every bit off the end of the number. A whole " \
              "number here has 32 bits. So the answer is the same whatever the number " \
              "holds. #{advice}#{at_dsl_line}"
      end

      # A zero written into the program as the number to divide by. Like the shift above it
      # is a mistake the build can read, and always a mistake: there is no answer, so the
      # game would be handed 1 or -1 (see IR::Int32.quotient_by_zero) and carry on with it.
      #
      # A divisor the game works out is left alone, since that one can come to nought on
      # some frame nobody foresaw. What it gives then is pinned, and the same everywhere.
      #
      # A fraction too small to keep counts as a written zero, because zero is what it is
      # stored as: a number here keeps a fixed count of fraction bits and rounds to them.
      def refuse_zero_divisor!(op, other)
        return unless other.is_a?(Numeric)

        too_small = other.is_a?(Float) && !other.zero? && Fraction.scale(other, Fraction.bits_of(other)).zero?
        return unless other.zero? || too_small

        advice =
          if too_small
            "The number #{other} is too small to keep, so it is kept as 0. Write a bigger number."
          else
            "Write a number that is not 0."
          end
        raise ArgumentError,
              "`#{op} #{other}` divides by zero. A division by zero has no answer. " \
              "#{advice}#{at_dsl_line}"
      end

      # A number that holds a fraction keeps that fraction in its own low bits, so a bit
      # operation on one changes the fraction rather than the number the author can see —
      # and nothing in the answer would show it. Refuse it and say which side is at fault.
      def whole_numbers_only!(op, other)
        return unless fraction? || Fraction.bits_of(other)

        side = fraction? ? "this number" : "the number on the right"
        raise ArgumentError,
              "`#{op}` works on whole numbers, and #{side} holds a fraction. A fraction " \
              "is kept in the low bits, so `#{op}` would change the fraction and not the " \
              "number you can see. Use `.to_i` first to drop the fraction.#{at_dsl_line}"
      end

      # An operation whose two sides must be at the same scale — adding, subtracting,
      # comparing. The result carries whatever scale they agreed on.
      def same_scale_binop(op, other)
        node = align!(other, describe_op(op))
        scaled(Build.binop(op, @node, node), @scale.bits || Fraction.bits_of(other))
      end

      # The rules for lining two scales up live in {Scale}, which is what a list and a pool
      # field ask directly.
      def align!(other, verb)
        @scale.node_matching(other, verb)
      end

      def operand_matching(other, verb)
        @scale.operand_matching(other, verb)
      end

      def node_at_scale(other, bits)
        Scale.node_at(other, bits)
      end

      def same_scale!(bits, verb)
        @scale.same_scale!(bits, verb)
      end

      # How the operator reads in a sentence, for an error message.
      def describe_op(op)
        case op
        when :+ then "add"
        when :- then "subtract"
        when :* then "multiply"
        when :/ then "divide"
        else "compare"
        end
      end

      # Where in the game's own source this went wrong — the first line of the caller
      # that is not inside the framework. Without it an error like this points at
      # value.rb, which is no help at all.
      def at_dsl_line
        frame = caller.find { |line| !line.include?("/lib/vblank/") }
        frame ? " (at #{frame[%r{[^/]+\.rb:\d+}] || frame})" : ""
      end

      # A new handle for +node+ carrying +bits+ fraction bits. An expression, so it never
      # names a variable.
      def scaled(node, bits)
        Value.new(@builder, node, fraction_bits: bits)
      end

      # A number worked out from this one by one of the five words that also have a `!` form,
      # at this one's scale — remembering how +bang+ would have changed this instead, when this
      # is a handle. A number worked out from a sum has nothing to change.
      def new_number(node, bang)
        Value.new(@builder, node, fraction_bits: @scale.bits, bang_spelling: handle? ? "#{name_as_written}.#{bang}" : nil)
      end

      # How the author wrote this handle, as near as it can be said: a variable's name.
      def name_as_written = @name.to_s

      # Run a mutation, returning self so calls chain — but only for a handle that
      # names a variable. Mutating an expression has nowhere to store the result.
      def mutate
        raise ArgumentError, NOT_A_VARIABLE unless @name

        yield
        self
      end

      # The IR node for an operand — the shared coercion (see Value.node_for).
      def node_of(other)
        Value.node_for(other)
      end
    end
  end
end
