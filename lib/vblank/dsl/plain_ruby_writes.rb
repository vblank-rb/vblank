# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # What a write does, whatever its spelling: `x = 1`, `x += 1`, `@x = 1`, `h[:x] = 1`,
      # `o.x = 1`. The rewrite says which place and which value, and this decides.
      module Writes
        # What `+=` and its relatives are on a game variable, where one exists. Any other
        # operator is the variable set to the sum.
        CHANGING_VERBS = { :+ => :increase!, :- => :decrease! }.freeze

        module_function

        # THE ONE DECISION. Every write comes here, whatever its spelling: +current+ is what the place
        # holds, +value+ what it is given, +tests+ the tests open around the line, +label+ the place as
        # the author wrote it. The block puts a value in the place, for Ruby's own kind of write. The
        # answer is what the name holds afterwards.
        #
        # A place holding a game variable keeps its variable, and the variable takes the number. A
        # plain place is Ruby's, until a test the game makes is open: both sides of that test run while
        # building, so a plain place would end up with the last side's value whichever way the game
        # goes. #promote has given anything that can follow the test a variable by then, so what is
        # still plain here cannot follow it, and stops with a plain error.
        #
        # +second_name+ is a name that holds a variable it did not make, which writes to it only under
        # a game test, after #promote has given it one of its own. +moves+ is an instance variable,
        # which goes to a variable it is given unless the one it holds is its own. +needs_slot+ is a
        # place that must exist already, so a new one under a game test is an error.
        def write(current, value, tests, label, second_name: false, moves: false, needs_slot: false)
          game = tests.any?(&:game?)
          return yield(value) if second_name && !game
          return write_plain_place(current, value, game, label, needs_slot) { |given| yield given } unless Steps.variable?(current)
          return current if value.equal?(current)

          if moves && Steps.variable?(value) && !current.own_to_its_name
            refuse_move_in_game_code!(label, current, value)
            return yield(value)
          end
          return store_and_keep(current, value) if number_kept?(value)
          return store_and_keep(current, value) unless current.truth || current.unwritten || game

          refuse_object_under_test!(label, value) unless current.truth || current.unwritten
          current.forget_truth!
          yield value
        end

        # A write the rewrite does not spell out, where no test is open.
        def give_variable(target, value) = write(target, value, [], :variable) { |given| given }

        def keeps_ruby_values?(collection) = collection.is_a?(Hash) || collection.is_a?(Array)

        def write_plain_place(current, value, game, label, needs_slot)
          refuse_object_under_test!(label, current) if game && !current.nil?
          refuse_new_place_under_test!(label) if game && needs_slot && number_kept?(value)
          yield value
        end

        def store_and_keep(variable, value)
          store_in_variable(variable, value)
          variable
        end

        # `x += amount`, and every operator like it, on any place. See #write.
        def change(current, operator, amount, tests, label, second_name: false)
          game = tests.any?(&:game?)
          return current.public_send(operator, amount) if second_name && !game
          return change_variable(current, operator, amount) if Steps.variable?(current)

          refuse_object_under_test!(label, current) if game
          yield current.public_send(operator, amount)
        end

        def change_variable(target, operator, amount)
          return write(target, Steps.bits(target, operator, amount), [], target.name) { |given| given } if joins_tests?(target, operator)

          verb = CHANGING_VERBS[operator]
          verb ? target.public_send(verb, amount) : target.store!(target.public_send(operator, amount))
          target
        end

        def joins_tests?(target, operator) = Steps.game_test?(target) && Steps::BIT_JOINS.include?(operator)

        # What a slot of a Hash or an Array holds, nil on anything else. A game's own list answers
        # `[]=` itself. A Hash is asked with `fetch`, since `[]` runs its default block for a key it does
        # not hold, and that block may be this very write.
        def slot(collection, keys, value)
          current = collection.fetch(keys.first, nil) if collection.is_a?(Hash)
          current = collection[*keys] if collection.is_a?(Array)
          refuse_new_slot!(collection, keys.first, value) if current.nil?
          current
        end

        # What an attribute holds. The library's own objects keep what they keep behind their setters,
        # so unless the attribute is a game variable the setter is left to do its work.
        def attribute(receiver, name)
          current = receiver.public_send(name) if receiver.respond_to?(name)
          Steps.variable?(current) || !receiver.class.name.to_s.start_with?("VBlank::") ? current : nil
        end

        # #promote for a place any method can reach. A game variable there is the place's own, and
        # the write changes it.
        def promote_place(value, test, *outer, may_stay_nil: false)
          Steps.variable?(value) ? value : promote(value, test, *outer, may_stay_nil: may_stay_nil)
        end

        # #promote for a slot of a Hash or an Array. A slot that holds nothing yet has no number to
        # keep, and a key a game works out is not a slot Ruby can name. A slot holding a game variable
        # is left alone, so a frozen Hash of a part's variables stays usable.
        def promote_slot(collection, keys, test, *outer)
          return unless (collection.is_a?(Hash) || collection.is_a?(Array)) && keys.none?(Value)

          current = slot(collection, keys, nil)
          collection[*keys] = promote_place(current, test, *outer) unless current.nil? || Steps.variable?(current)
        end

        # #promote for an attribute of an object of the game's own.
        def promote_attribute(receiver, name, test, *outer)
          current = attribute(receiver, name)
          receiver.public_send(:"#{name}=", promote_place(current, test, *outer)) unless current.nil? || Steps.variable?(current)
        end

        # Put +value+ in a game variable. A yes or no is kept as 1 or 0, and a test's answer is
        # worked out as the game plays.
        def store_in_variable(target, value)
          return store_with_truth(target, value) if target.truth

          case value
          when true then target.store!(1)
          when false, nil
            refuse_nothing_in_number!(target, value) unless target.boolean?
            target.store!(0)
          when Condition then store_answer(target, value)
          else
            refuse_number_in_boolean!(target) if target.boolean? && value.is_a?(Value) && !value.boolean?
            target.store!(value)
          end
        end

        # The same, on a name that keeps what it holds (see Value#truth).
        def store_with_truth(target, value)
          case value
          when nil then target.truth.store!(Value::NIL_HELD)
          when false then target.truth.store!(Value::FALSE_HELD)
          when true then store_truthy(target, 1)
          when Condition then store_truth_of_test(target, value)
          when Value then store_value_with_truth(target, value)
          else store_truthy(target, value)
          end
        end

        def store_truthy(target, number)
          target.store!(number)
          target.truth.store!(Value::TRUTHY_HELD)
        end

        def store_truth_of_test(target, condition)
          answer = Steps::GameTest.new(condition)
          answer.open_yes_side
          store_truthy(target, 1)
          answer.close_side(nil)
          answer.open_no_side
          store_with_truth(target, false)
          answer.close_side(nil)
        end

        def store_value_with_truth(target, value)
          return store_truthy(target, value) unless value.truth

          target.store!(value)
          target.truth.store!(value.truth)
        end

        # The first line of a name that can hold nil or false as well as a number.
        def start_with_truth(value)
          own = yield(0)
          return own.tap(&:start_truth_as_nil!) if value.nil?

          own.keep_truth!
          store_with_truth(own, value)
          own
        end

        def store_answer(target, condition)
          answer = Steps::GameTest.new(condition)
          answer.open_yes_side
          target.store!(1)
          answer.close_side(nil)
          answer.open_no_side
          target.store!(0)
          answer.close_side(nil)
        end

        # A plain name is about to be changed under +test+. A test the game makes runs both sides
        # while building, so a plain name would end up with the last side's value whichever way
        # the game goes. It gets a hidden variable holding its value now, and the sides change that.
        #
        # Tests already open around this one have seen to a name read after them, in +outer+. One read
        # only inside them, and still holding a variable it was handed, gets its own here: the sides
        # would otherwise write the variable it came from, which is somebody else's.
        def promote(value, test, *outer, may_stay_nil: false)
          return value unless test.game?
          return value if outer.any?(&:game?) && !(Steps.variable?(value) && handed?(value))
          return value unless number_kept?(value)

          own = test.hidden_variable(:promoted, like: value.is_a?(Value) ? value : nil)
          own.mark_boolean! if [true, false].include?(value) || value.is_a?(Condition) || (value.is_a?(Value) && value.boolean?)
          own.unwritten = value.nil?
          own.start_truth_as_nil! if may_stay_nil && value.nil?
          store_in_variable(own, value) unless value.nil?
          own
        end

        # `@a = @b` in code the game runs, where @a was only handed its variable. Copying into it
        # would change a variable that belongs to something else, and moving it would leave a line
        # that looks like a copy recording nothing, so the author says which.
        def refuse_move_in_game_code!(label, current, value)
          return unless Builder.in_use&.recording_game_code?

          Steps.refuse_game_code!("`#{label}` was handed the game variable :#{current.name}, and this line gives it " \
                                  ":#{value.name}. The game would see no change. To fix this, give `#{label}` a " \
                                  "variable of its own with `#{label} = var :#{label.to_s.delete('@')}, 0`, and the " \
                                  "line then copies the number.")
        end

        # A name in code the game runs, holding a variable it was handed, is about to be given
        # +value+. The line moves the name and leaves the variable as it was, so the build says so.
        # A hidden copy (`left = hp`) is the name's own number, and changing it is the point.
        def note_handed_name_written(current, value, label)
          return unless Steps.variable?(current) && !value.equal?(current) && handed?(current)

          builder = Builder.in_use
          builder.record_handed_name_write(label, current.name) if builder&.recording_game_code?
        end

        # A handle with no name is a field of a pool or the like, which the library's own code
        # works on and an author never wrote.
        def handed?(variable)
          name = variable.name.to_s
          !name.empty? && !name.start_with?(IR::Build::KEPT_VARIABLE_PREFIX)
        end

        def refuse_change_in_block!(name, tests)
          return unless tests.any?(&:game?)

          Steps.refuse_game_code!("`#{name}` is changed inside a block, under a test the game makes as it plays. The " \
                            "block runs while building, so the game cannot follow this. To fix this, start it " \
                            "with `#{name} = var :#{name}, 0`.")
        end

        def refuse_begin_while!(name)
          Steps.refuse_game_code!("This `begin` loop changes `#{name}`, and its test is one the game makes as it plays. " \
                            "To fix this, start it with `#{name} = var :#{name}, 0`.")
        end

        def refuse_number_in_boolean!(target)
          Steps.refuse_game_code!("`#{target.name}` started as `true` or `false`, and this line gives it a number. A " \
                            "game variable keeps one kind unless the line says so. To fix this, compare the " \
                            "number, like `#{target.name} = count > 0`, or start it with a number.")
        end

        def refuse_nothing_in_number!(target, value)
          Steps.refuse_game_code!("`#{target.name}` holds a number, and this line gives it `#{value.inspect}`. To fix " \
                                  "this, start it with `#{target.name} = nil`.")
        end

        def refuse_new_place_under_test!(label)
          Steps.refuse_game_code!("`#{label}` has no number yet, and this line gives it one under a test the game " \
                                  "makes as it plays. To fix this, give it a number before the test.")
        end

        def refuse_object_under_test!(name, held)
          shown = held.is_a?(String) ? held.inspect : "a #{held.class.name.split('::').last}"
          Steps.refuse_game_code!("`#{name}` holds #{shown}, and this line changes it under a test the game makes " \
                            "as it plays. A game can keep only numbers, symbols, `true` and `false`. To fix this, " \
                            "keep a number and pick with it.")
        end

        # A variable the author never wrote `var` for, which the out-of-memory error names.
        #
        # A game block runs on the builder, which has `var`. A part of a game is a plain class
        # that holds one, so the variable comes from the builder in use, under a name nothing has
        # taken: two parts, or two of one part, each have a local of their own, as in Ruby.
        def variable_with_no_var_line(owner, name, start)
          variable = owner.respond_to?(:var, true) ? owner.__send__(:var, name, start) : variable_for_part(name, start)
          variable.note_made_with_no_var_line
          variable
        end

        def variable_for_part(name, start)
          builder = Builder.in_use
          Steps.refuse_game_code!("`#{name}` is changed by game code, but no game is being built. To fix this, " \
                            "make this part while a game is being built.") if builder.nil?

          builder.var(builder.free_variable_name(name), start)
        end

        # Is this something a game can keep, as opposed to an object only Ruby can hold? The one
        # answer to that, asked of the value as the line runs.
        def number_kept?(value) = value.nil? || Steps.game_value?(value) || value.is_a?(Value) || value.is_a?(Condition)

        # The first line of a name the game changes later. A number starts a variable. A variable or
        # a working-out gives it a variable of its own holding that number now, since a Ruby name
        # holds a value and never another name. Anything else stays what it is.
        def start_name(value)
          return yield(value) if Steps.game_value?(value)

          case value
          when Condition then give_variable(yield(false), value)
          when Value then give_variable(own_variable(value) { |start| yield(start) }, value)
          else value
          end
        end

        def own_variable(value)
          own = yield(value.fraction? ? 0.0 : 0)
          own.mark_boolean! if value.boolean?
          own
        end

        # `@x = var :x, 0`. A part of a game keeps its variables in these, and this one is the name's
        # own, so #reassign can tell it from one the name was only handed.
        def keep_as_own(variable)
          variable.own_to_its_name = true
          variable
        end

        # A number given to a key that a Hash of game variables does not hold is a misspelt key: it
        # would go in as a plain Ruby number, and the game's variable would stay as it was.
        def refuse_new_slot!(collection, key, value)
          return unless collection.is_a?(Hash) && !collection.empty? && Steps.game_value?(value) && !value.is_a?(Symbol)
          return unless collection.each_value.all? { |each_value| Steps.variable?(each_value) }

          Steps.refuse_game_code!("This Hash holds game variables and has no key #{key.inspect}, so the game would never " \
                  "see this number. The keys are #{collection.keys.map(&:inspect).join(', ')}. To fix " \
                  "this, use one of those keys.")
        end

        # A plain number changed by code the game runs would change once, while building, and the
        # game would never see it. See Rewriter#guarded_write_text.
        def refuse_lost_number!(name, recording_game_code)
          return unless recording_game_code

          Steps.refuse_game_code!("`#{name}` is a plain number, and this line runs as the game plays, so the game " \
                  "will never see the change. To fix this, start it with `#{name} = var :#{name}, 0`.")
        end
      end
    end
  end
end
