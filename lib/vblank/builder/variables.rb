# frozen_string_literal: true

module VBlank
  class Builder
    # Variables and arithmetic
    #
    # A variable is a number your game keeps and changes while it runs: a score, a position, a
    # speed. You make one with plain Ruby (`hp = 10`, then `hp -= 1`), or with `var` when you want
    # to say more about it, such as how much room it needs. Fractions, names (`mode = :title`)
    # and yes or no values (`alive = true`) work too.
    #
    # ```ruby
    # VBlank.game "COUNTER" do
    #   score = 0
    #   game_loop do
    #     score += 1
    #     score = 0 if score > 99
    #   end
    # end
    # ```
    #
    # A variable that must survive turning the console off is a `save_var`. Words such as
    # `negate!`, `abs!`, `clamp!` and `approach!` change a variable in place; the same words
    # without the `!` are on the variable's own handle and give a new number instead.
    #--
    # The list of names itself (ensure_var / the @variables set) is builder core,
    # shared by every concern, so it stays in Builder; these verbs just record the ops
    # and lean on it. A concern of Builder, mixed in so these stay flat DSL verbs.
    #++
    module Variables
      # Set a variable's value. If the variable hasn't been declared yet, it is
      # declared here. Returns a {Value} handle for the variable, so it can be
      # compared and mutated with the expression DSL.
      #
      # @param name [Symbol] variable name
      # @param value [Integer] value to store
      # @return [Value] a handle to the variable
      # Called by a variable's own handle (`Value#store!`), not written in a game.
      def store!(name, value)  # :nodoc:
        record(Build.set(name, stored_node(name, value)))
        ensure_var(name)
        mirror_save(name)
        value_handle_for(name)
      end

      # Declares a variable with a starting value and returns a handle to it.
      #
      # Plain Ruby (`hp = 10`) makes a variable for you. Use `var` when you want to say more:
      # the starting value is set once, when the game starts, even if the `var` is written inside
      # a scene or a loop that runs many times. That lets a scene declare its own score or flag
      # where it uses it.
      #
      # A starting value that is a name, as in `var :mode, :title`, makes a variable that holds
      # one of a set of names instead of a count: the states a game can be in, the moves an enemy
      # can make. Write `mode = :playing` and `mode == :playing` as they look, and `call mode`
      # runs the routine of that name.
      #
      # A variable that only ever holds a small number can say so: `var :flag, 0, width: :byte`
      # keeps it in one byte. It reads and works the same, and costs less memory and time on the
      # consoles that are short of both. A number too big for the width keeps only its low bits.
      #
      # ```ruby
      # var :lives, 3
      # var :state, :title                 # one of a set of names
      # var :frame_count, 0, width: :half  # never above 32767
      # ```
      #
      # * `name` - the variable's name, as a symbol.
      # * `value` - the starting value: a whole number, a fraction, `true` or `false`, or a name.
      # * `width:` - `:byte` or `:half` to keep it narrow; `:word` keeps the whole number.
      #--
      # Unlike #set (a runtime assignment that happens where you write it), a declaration's
      # initial value is applied once, at program start. Names get numbers in the order they
      # first appear (see DSL::NameSet). A narrow width is kept by IR::KeptWidths.
      #++
      def var(name, value, width: :word)
        if [true, false].include?(value)
          remember_boolean_variable(name)
          value = value ? 1 : 0
        end
        refuse_conflicting_declaration!(name, value, width: width)
        ensure_var(name)
        @name_vars[name] ||= DSL::NameSet.new("the variable :#{name}") if value.is_a?(Symbol)
        # A build started in a chosen state starts it there instead (Game#starting_with).
        if chosen_start?(name)
          start = chosen_variable_start(name, value)
          keep_narrow(name, width, start)
          at_boot(chosen_start_set(name, start))
        else
          keep_narrow(name, width, value)
          at_boot(Build.set(name, stored_node(name, value)))
        end
        add_part_member(:var, name)
        value_handle_for(name)
      end

      # Note +name+ as kept at +width+, refusing a width that is not one and a start it cannot hold.
      def keep_narrow(name, width, start)
        return if width == :word
        unless IR::KeptWidths::BYTES.key?(width)
          raise ArgumentError, "The variable :#{name} says `width: #{width.inspect}`. A width is :byte, :half or " \
                               ":word. To fix this, give one of those."
        end
        if start.is_a?(Float)
          raise ArgumentError, "The variable :#{name} is a fraction and says `width: :#{width}`. A fraction needs the " \
                               "whole number. To fix this, remove `width:`."
        end

        refuse_number_too_wide!(name, width, start) if start.is_a?(Integer) && !start.between?(IR::KeptWidths.lowest(width), IR::KeptWidths.highest(width))
        @kept_widths[name] = width
      end

      def refuse_number_too_wide!(name, width, number)
        raise ArgumentError, "The variable :#{name} is kept as a #{width} (`width: :#{width}`), but the game sets it to " \
                             "#{number}. A #{width} holds #{IR::KeptWidths.lowest(width)} to #{IR::KeptWidths.highest(width)}. " \
                             "To fix this, use a number in that range, or give the variable a bigger width."
      end

      # Every change of a narrow variable followed by its wrap (see {IR::KeptWidths}): last of all,
      # once the framework's own statements are in the tree too.
      def finalize_kept_widths
        return if @kept_widths.empty?

        @program.kept_widths = @kept_widths.to_a
        IR::KeptWidths.add_wraps(@program, @kept_widths) { |name, width, number| refuse_number_too_wide!(name, width, number) }
      end
      # The variables and lists that hold fractions, written on the program for whatever reads the
      # running game back (Program#fraction_vars). A pool's field holds fractions when its default
      # is one, and is a list of the pool's.
      def finalize_fractions
        fields = declared_pools.flat_map do |pool|
          pool.field_names.filter_map do |field|
            bits = pool.field_bits(field)
            [pool.field_list(field), bits] if bits
          end
        end
        @program.fraction_vars = @fraction_vars.to_a unless @fraction_vars.empty?
        lists = @fraction_lists.to_a + fields
        @program.fraction_lists = lists unless lists.empty?
      end
      private :keep_narrow, :refuse_number_too_wide!, :finalize_kept_widths, :finalize_fractions

      # A variable started with `true` or `false` holds a yes or no, kept as 1 or 0. It is the one
      # kind a game can test on its own, `if alive`, as a Ruby value can be.
      # Called by a variable's own handle, not written in a game.
      def remember_boolean_variable(name)  # :nodoc:
        @boolean_variables[name] = true
      end

      # Called by a variable's own handle, not written in a game.
      def boolean_variable?(name) = @boolean_variables.key?(name)  # :nodoc:

      # Declares a variable whose value is still there after the console is turned off, such as a
      # high score, an unlock or a setting.
      #
      # It works like `var`: you get the same handle and use it the same way. The difference is
      # where the value lives. It is kept in the cartridge's save memory, so:
      #
      # * At power-on it comes back with the value it had last time, or with `default` the very
      #   first time the game runs, when nothing is saved yet.
      # * Each time you change it, the new value is saved for you. There is no separate save step.
      #
      # ```ruby
      # high = save_var :high_score, 0
      # high = score if score > high   # a new record, saved on the spot
      # ```
      #
      # * `name` - the variable's name, as a symbol.
      # * `default` - a whole number: the value on a new cartridge.
      def save_var(name, default)
        unless default.is_a?(Integer)
          raise ArgumentError,
                "save_var's default must be a whole number. This is the value on a " \
                "fresh cartridge. You gave #{Messages::PlainWords.words_for_given(default)}."
        end

        refuse_conflicting_declaration!(name, default, saved: true)
        ensure_var(name)
        unless persisted?(name)
          IR::SaveLayout.save_var_at(@persisted.length) # refuses one more than save memory holds
          @persisted << IR::SavedVar.new(name: name, default: default, slot: @persisted.length)
        end
        value_handle_for(name)
      end


      # Add to a variable: var += operand.
      # Operand can be an immediate (Integer) or another variable (Symbol).
      #
      # @param name [Symbol] variable name
      # @param operand [Integer, Symbol] value to add
      # Called by a variable's own handle, not written in a game.
      def increase!(name, operand)  # :nodoc:
        record(Build.add(name, DSL::Value.node_for(operand)))
        ensure_var(name)
        ensure_var(operand)
        mirror_save(name)
      end

      # Subtract from a variable: var -= operand.
      # Operand can be an immediate (Integer) or another variable (Symbol).
      #
      # @param name [Symbol] variable name
      # @param operand [Integer, Symbol] value to subtract
      # Called by a variable's own handle, not written in a game.
      def decrease!(name, operand)  # :nodoc:
        record(Build.sub(name, DSL::Value.node_for(operand)))
        ensure_var(name)
        ensure_var(operand)
        mirror_save(name)
      end

      # Flips a variable's sign, so 5 becomes -5 and -5 becomes 5.
      #
      # Use it to turn a speed round. `flip!` is the same verb.
      #
      # ```ruby
      # dx.flip! if x > 232   # bounce off the right edge
      # ```
      #
      # * `name` - the variable to change, as a symbol or its handle.
      def negate!(name)
        record(Build.negate(name))
        ensure_var(name)
        mirror_save(name)
      end
      alias flip! negate!

      # Copy one variable's value into another: dest = src.
      #
      # @param dest [Symbol] destination variable
      # @param src [Symbol] source variable
      # Called by a variable's own handle, not written in a game.
      def copy_variable!(dest, src)  # :nodoc:
        record(Build.copy(dest, src))
        ensure_var(dest)
        ensure_var(src)
        mirror_save(dest)
      end

      # Makes a variable positive: a negative number loses its sign, and any other is left alone.
      #
      # ```ruby
      # distance = x - target
      # distance.abs!   # how far apart they are, whichever side
      # ```
      #
      # Without the `!`, `distance.abs` gives the positive number and leaves the variable as it is.
      #
      # * `name` - the variable to change, as a symbol or its handle.
      def abs!(name)
        record(Build.abs(name))
        ensure_var(name)
        mirror_save(name)
      end

      # Makes a variable negative: a positive number gets a minus sign, and any other is left alone.
      #
      # ```ruby
      # speed.negate_abs!   # always heading left, whatever it was
      # ```
      #
      # * `name` - the variable to change, as a symbol or its handle.
      def negate_abs!(name)
        record(Build.negate_abs(name))
        ensure_var(name)
        mirror_save(name)
      end

      # EVERY FLAT VERB WITHOUT ITS `!`. A word without `!` never changes a variable, so each
      # says which word does — and, where there is one, how to get the same number without
      # changing anything (see {ChangingWord}).
      #
      # A number is what `abs` and its four neighbours give back, on the variable's own handle;
      # for adding and subtracting it is what `+` and `-` already are; and `set` and `copy`
      # have no such form, since neither answers a question about a number.
      CHANGING_HANDLE_WORDS = { abs: :abs, negate_abs: :negate_abs, negate: :flip, flip: :flip,
                                clamp: :clamp, approach: :approach }.freeze
      CHANGING_OPERATOR_WORDS = { add: :+, sub: :-, add_var: :+, sub_var: :- }.freeze

      # The words plain Ruby has an operator for, which is what a game writes.
      PLAIN_RUBY_OPERATORS = { set: "=", copy: "=", add: "+=", add_var: "+=", sub: "-=", sub_var: "-=" }.freeze

      # :method: set
      #
      # Is not used any more. Assign with plain Ruby instead: `hp = 10`.
      #
      # Calling `set :hp, 10` raises an error that says so, with the line to write instead.
      #
      # * `name` - the variable.
      # * `value` - the number to store.

      # :method: copy
      #
      # Is not used any more. Assign with plain Ruby instead: `x = y`.
      #
      # Calling `copy :x, :y` raises an error that says so, with the line to write instead.
      #
      # * `dest` - the variable to change.
      # * `src` - the variable to read.

      # :method: add
      #
      # Is not used any more. Add with plain Ruby instead: `x += 1`.
      #
      # Calling `add :x, 1` raises an error that says so, with the line to write instead.
      #
      # * `name` - the variable.
      # * `operand` - the number to add.

      # :method: add_var
      #
      # Is not used any more. Add one variable to another with plain Ruby instead: `x += y`.
      #
      # Calling `add_var :x, :y` raises an error that says so, with the line to write instead.
      #
      # * `name` - the variable.
      # * `operand` - the variable to add.

      # :method: sub
      #
      # Is not used any more. Subtract with plain Ruby instead: `x -= 1`.
      #
      # Calling `sub :x, 1` raises an error that says so, with the line to write instead.
      #
      # * `name` - the variable.
      # * `operand` - the number to subtract.

      # :method: sub_var
      #
      # Is not used any more. Subtract one variable from another with plain Ruby instead: `x -= y`.
      #
      # Calling `sub_var :x, :y` raises an error that says so, with the line to write instead.
      #
      # * `name` - the variable.
      # * `operand` - the variable to subtract.

      # :method: abs
      #
      # Does not change a variable. To make one positive, write `x.abs!`. To get the positive
      # number and leave the variable as it is, write `x.abs` on its handle.
      #
      # Calling `abs :x` raises an error that says so.

      # :method: negate_abs
      #
      # Does not change a variable. To make one negative, write `x.negate_abs!`. To get the
      # negative number and leave the variable as it is, write `x.negate_abs` on its handle.
      #
      # Calling `negate_abs :x` raises an error that says so.

      # :method: negate
      #
      # Does not change a variable. To flip its sign, write `x.negate!` (or `x.flip!`). To get the
      # flipped number and leave the variable as it is, write `x.flip` on its handle.
      #
      # Calling `negate :x` raises an error that says so.

      # :method: flip
      #
      # Does not change a variable. To flip its sign, write `x.flip!`. To get the flipped number
      # and leave the variable as it is, write `x.flip` on its handle.
      #
      # Calling `flip :x` raises an error that says so.

      # :method: flip!
      #
      # Flips a variable's sign, so 5 becomes -5 and -5 becomes 5. It is the same verb as
      # `negate!`.
      #
      # ```ruby
      # dx.flip! if x > 232   # bounce off the right edge
      # ```

      # :method: clamp
      #
      # Does not change a variable. To hold one inside a range, write `x.clamp! 0, 239`. To get
      # the held number and leave the variable as it is, write `x.clamp(0, 239)` on its handle.
      #
      # Calling `clamp :x, 0, 239` raises an error that says so.

      # :method: approach
      #
      # Does not change a variable. To move one toward a target, write `x.approach! target, step`.
      # To get the new number and leave the variable as it is, write `x.approach(target, step)`
      # on its handle.
      #
      # Calling `approach :x, target, step` raises an error that says so.

      # Written out as source rather than made from a block, so another Ractor can call them —
      # see {IR::Node.operands} for why a block-backed method cannot be.
      (CHANGING_HANDLE_WORDS.keys + CHANGING_OPERATOR_WORDS.keys + %i[set copy]).each do |verb|
        class_eval <<~REFUSAL, __FILE__, __LINE__ + 1
          def #{verb}(name = nil, *rest)
            raise ArgumentError, changing_verb_message(:#{verb}, name, rest)
          end
        REFUSAL
      end

      # Holds a variable inside a range: below the lowest it becomes the lowest, above the highest
      # it becomes the highest, and in between it is left alone.
      #
      # The limits can be fixed numbers or things the game works out as it runs, such as a limit
      # that depends on the level.
      #
      # ```ruby
      # x.clamp! 0, 239              # keep it on screen
      # speed.clamp! 0, top_speed    # a limit the game changes
      # ```
      #
      # Without the `!`, `x.clamp(0, 239)` gives the held number and leaves the variable as it is.
      #
      # * `name` - the variable to change.
      # * `min_val` - the lowest it may be: a number, a variable or a handle.
      # * `max_val` - the highest it may be.
      def clamp!(name, min_val, max_val)
        record(Build.clamp(name, DSL::Value.node_for(min_val), DSL::Value.node_for(max_val)))
        ensure_var(name)
        ensure_var(min_val)
        ensure_var(max_val)
        mirror_save(name)
      end

      # Moves a variable toward a target by at most one step each time it runs, and never past it.
      #
      # Once the variable is within a step of the target it lands exactly on it and stays there.
      # Use it to chase with a top speed: an enemy that homes in, a camera that eases to the
      # player, a paddle that tracks the ball.
      #
      # ```ruby
      # cpu_y.approach! ball_y - PADDLE_H / 2, CPU_SPEED
      # ```
      #
      # The step can be a fixed number or something the game works out as it runs, such as an
      # easing whose speed depends on how far there is to go. A fixed step must be above 0. A step
      # the game works out is read as a distance, so a negative one still moves toward the target
      # and a step of 0 holds still.
      #
      # * `name` - the variable to move.
      # * `target` - where it is heading: a number, a variable or a calculation.
      # * `step` - the most it may move each time it runs.
      def approach!(name, target, step)
        # A step the author fixed has to be positive. One the game works out is read as a
        # distance instead (see #emit_approach_bounds), so there is nothing to check here.
        fixed_step = DSL::Value.fixed_number(step)
        if fixed_step && !fixed_step.positive?
          raise ArgumentError, "approach's step must be positive. You gave #{fixed_step}."
        end

        ensure_var(name)
        ensure_var(target)
        delta = next_approach_var
        ensure_var(delta)
        # How far there is to go, capped to a single step in either direction, then
        # applied — a branchless move that can't overshoot: when the target is
        # already within one step, the cap does nothing and it lands right on it.
        record(Build.set(delta, Build.binop(:-, DSL::Value.node_for(target), Build.var_ref(name))))
        low, high = emit_approach_bounds(step)
        record(Build.clamp(delta, low, high))
        record(Build.add(name, Build.var_ref(delta)))
        mirror_save(name)
      end

      # The name of every variable the game has, in the order it first named each.
      # Where each is kept is the lowering's to decide (a built cartridge's
      # var_addresses gives it).
      # @return [Array<Symbol>]
      # Introspection for the build, not a verb: a game names its variables itself.
      def variables  # :nodoc:
        @variables.to_a
      end

      private

      # What one of those says: the line as it was written, what changes the variable, and where
      # the same number comes from instead.
      def changing_verb_message(verb, name, rest)
        written = DSL::ChangingWord.arguments_text([name, *rest])
        said = written.empty? ? "" : " #{written}"
        at = Messages::AuthorSource.at_author_line
        operator = PLAIN_RUBY_OPERATORS[verb]
        instead = new_number_advice(verb, name, rest)
        return DSL::ChangingWord.refusal(written: "#{verb}#{said}", bang: "#{verb}!#{said}", instead: instead, at: at) unless operator

        fix = [name, operator, rest.first || 1].map { |part| DSL::ChangingWord.as_source_text(part) || "1" }.join(" ")
        DSL::ChangingWord.plain_ruby_refusal(written: "#{verb}#{said}", fix: fix, instead: instead, at: at)
      end

      # The words a game used to change a variable with, kept private so that the sentence
      # reaches a line in a game block, where they need no receiver.
      %i[set! add! add_var! sub! sub_var! copy!].each do |word|
        class_eval <<~REFUSAL, __FILE__, __LINE__ + 1
          def #{word}(*)
            raise DSL::PlainRuby::Refused, DSL::ChangingWord.old_verb_refusal(:#{word}, at: Messages::AuthorSource.at_author_line)
          end
          private :#{word}
        REFUSAL
      end

      def new_number_advice(verb, name, rest)
        return DSL::ChangingWord.operator_advice(name, CHANGING_OPERATOR_WORDS[verb], rest.first, handles: true) unless CHANGING_HANDLE_WORDS.key?(verb)

        handle = name.is_a?(Symbol) ? "the handle that `var :#{name}` gives you" : "the variable's handle"
        " To get a new number and keep the variable as it is, use " \
          "`.#{CHANGING_HANDLE_WORDS.fetch(verb)}` on #{handle}."
      end

      # A handle for a variable, carrying a fraction if that is what it holds. Every
      # route to a variable goes through here, so `var :px, 3.5` and a later
      # `set :px, ...` hand back handles that agree about what the variable is.
      def value_handle_for(name)
        DSL::Value.new(self, Build.var_ref(name), name: name, fraction_bits: @fraction_vars[name],
                                             names: @name_vars[name])
      end

      # A name is one variable however many places declare it. That is what lets a game
      # object write `var :score, 0` in setup that runs more than once, and it is also how two
      # parts of a game that each wanted a scratch `_seen` end up writing the same one with
      # nothing to say so — found later by a wrong picture. Two declarations that agree are
      # the first case and pass; two that start the variable differently (a fraction and a
      # whole number, or two different numbers) can only be the second. So can a `save_var`
      # and a `var` of one name: the plain one would quietly be saved and loaded too.
      def refuse_conflicting_declaration!(name, value, saved: false, width: :word)
        instance_variable_uses.refuse_var_on_part_variable!(name) if @var_declarations.key?(name)
        start = value.is_a?(DSL::Value) ? value.node : value
        here = Declaration.new(start: start, saved: saved, width: width, at: Messages::AuthorSource.author_file_and_line)
        first = (@var_declarations[name] ||= here)
        return if first.agrees_with?(here)

        raise ArgumentError,
              "The variable :#{name} has two declarations that do not agree. " \
              "#{first.describe('first')} #{here.describe('second')} " \
              "One name is one variable, so both places change the same value. " \
              "If they are two different things, give each one its own name. " \
              "If they are one thing, make both declarations the same."
      end

      # One `var` or `save_var`: what it started the variable at, whether it is kept across
      # power-off, and the line of the game that wrote it.
      Declaration = Data.define(:start, :saved, :width, :at) do
        # Ruby says 0.0 == 0, and a fraction and a whole number are exactly the two kinds
        # that must not pass as the same, so the class has to match as well as the value.
        def agrees_with?(other)
          saved == other.saved && width == other.width && start.instance_of?(other.start.class) && start == other.start
        end

        # "At hero.rb:12 it starts at 0.0, a fraction." — for the message above.
        def describe(which)
          what = case start
                 when Float then "#{start}, a fraction"
                 when Integer then "#{start}, a whole number"
                 when Symbol then ":#{start}, one of a set of names"
                 else "a value the game works out"
                 end
          kept = saved ? " and is kept when the power is off" : ""
          kept += " and is kept as a #{width}" unless width == :word
          "#{at ? "At #{at}" : "In the #{which} place"} it starts at #{what}#{kept}."
        end
      end

      # The node to store in +name+. A variable that holds NAMES turns the one it was given
      # into that name's number; everything else keeps the meaning it has everywhere — a bare
      # symbol is another variable, and a Float marks the variable as holding a fraction.
      def stored_node(name, value)
        held = @name_vars[name]
        return Build.int(held.number_for(value)) if held && value.is_a?(Symbol)

        number_node_noting_fraction!(name, value)
      end

      # The node to store in +name+, remembering whether that variable holds a
      # fraction. Writing a Float — `var :px, 3.5` — is how a program marks that it does; the
      # scale is then carried by every handle for that variable and never written again.
      def number_node_noting_fraction!(name, value)
        bits = DSL::Fraction.bits_of(value)
        @fraction_vars[name] = bits if bits
        return Build.int(DSL::Fraction.scale(value, bits)) if value.is_a?(Float)

        DSL::Value.node_for(value)
      end

      # A fresh hidden variable to hold one approach call's capped delta. Named per
      # call site at build time, so an approach inside a loop reuses the one
      # variable every frame rather than allocating forever.
      def next_approach_var
        @approach_seq += 1
        :"__approach_#{@approach_seq}".tap { |name| @unique_names << name }
      end

      # How far one approach call may move, in each direction — the pair of bounds its
      # delta is held between.
      #
      # A fixed step is just the number and its negative. A step the game works out
      # goes through a hidden variable first, so it can be read as a DISTANCE: a
      # negative one would otherwise invert the range and drive the variable away from
      # its target for ever, which is silent and looks like a physics bug. Taking the
      # size of it means the step sets how fast, and the target sets which way.
      def emit_approach_bounds(step)
        fixed = DSL::Value.fixed_number(step)
        return [-fixed, fixed] if fixed

        limit = next_approach_var
        ensure_var(limit)
        ensure_var(step)
        record(Build.set(limit, DSL::Value.node_for(step)))
        record(Build.abs(limit))
        [Build.binop(:-, Build.int(0), Build.var_ref(limit)), Build.var_ref(limit)]
      end
    end
  end
end
