# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # What a write does, whatever its spelling: `x = 1`, `x += 1`, `@x = 1`, `h[:x] = 1`,
      # `o.x = 1`. The rewrite gives which place and which value, and this decides.
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
        # place that must exist already, so a new one under a game test is an error. +copies+ is an
        # instance variable game code gives another name (LocalNames#moved_in_game_code?), which
        # keeps a variable of its own and copies each number into it.
        #
        # +before_plain_start+ counts the outermost of +tests+ that opened before a line gave the name
        # a value outright (Rewriter#tests_open_before_plain_start). See #tests_followed.
        #
        # +owner+ is the object an instance variable belongs to, for a game's own instance variable
        # (InstanceVariables.write_target): one the game names is its game variable by now. +starting+
        # is a write in its `initialize`.
        def write(current, value, tests, label, second_name: false, moves: false, needs_slot: false, copies: false,
                  before_plain_start: 0, owner: nil, starting: false)
          if owner
            InstanceVariables.refuse_nil_written_under_game_test!(owner, current, label, tests)
            first = InstanceVariables.first_variable(owner, current, value, label)
            # A Hash or Array of game variables is a start wherever it is given: no line sets it whole.
            if first && (!Steps.variable?(first) || !InstanceVariables.first_number_set_where_reached?(starting))
              return first
            end

            current = first || InstanceVariables.write_target(owner, current, value, label, starting: starting)
          end
          game = tests_followed(current, tests, before_plain_start).any?(&:game?)
          return yield(value) if second_name && !game
          return yield(own_copy(label, value)) if copies && Steps.variable?(value) && !own_variable?(current)
          return write_plain_place(current, value, game, label, needs_slot) { |given| yield given } unless Steps.variable?(current)
          return current if value.equal?(current)

          # A hidden variable is a number the build kept (a copy, a pick), never a handle to move.
          if moves && Steps.variable?(value) && !value.hidden? && !current.own_to_its_name
            refuse_move_in_game_code!(label, current, value, owner)
            return yield(value)
          end
          return store_and_keep(current, value) if number_kept?(value)
          return store_and_keep(current, value) unless current.truth || current.unwritten || game

          refuse_object_under_test!(label, value) unless current.truth || current.unwritten
          current.forget_truth!
          yield value
        end

        # The tests a write to a place holding +current+ has to follow. A game variable follows every
        # open test. A plain value given to the name inside a test, by a line every way to this write
        # runs, is the same whichever way that test and the ones around it go, so the write follows
        # only the tests opened since: a counter set to 0 at the top of a game's loop and counted by
        # a loop of Ruby's inside it is plain Ruby, written out, on every round.
        def tests_followed(current, tests, before_plain_start)
          Steps.variable?(current) ? tests : tests.drop(before_plain_start)
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
        #
        # The operator is the one the game wrote, which the rewritten line hands here as a Symbol, so it
        # is applied the way Ruby applies it, by public_send: that is Ruby itself, on purpose, and the
        # same goes for the verbs, attributes and setters below.
        #
        # +owner+ is #write's.
        def change(current, operator, amount, tests, label, second_name: false, before_plain_start: 0, owner: nil,
                   starting: false)
          current = InstanceVariables.change_target(owner, current, label, starting: starting) if owner
          game = tests_followed(current, tests, before_plain_start).any?(&:game?)
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
          # A named field of a Struct made in game code, read without counting as a read the game makes.
          return InstanceVariables.field_before_write(receiver, name) if InstanceVariables.named_field?(receiver, name)

          current = receiver.public_send(name) if receiver.respond_to?(name)
          Steps.variable?(current) || !receiver.class.name.to_s.start_with?("VBlank::") ? current : nil
        end

        # #promote for a place any method can reach. A game variable there is the place's own, and
        # the write changes it. +owner+ and +label+ name a game's own instance variable, as #write's do.
        # The variable a promotion makes is the place's own too, so a later line giving the place
        # another game variable (`@held = @states[0]`) copies the number into it.
        #
        # A named instance variable still holding nil is left as it is. The line that sets it may be
        # one this build skips, under a test decided while building (`@secret = called if
        # @secret_floor`, with `@secret_floor` false), and then no game code reads or writes it, so
        # it has no variable. Where the line does run, its write decides
        # (InstanceVariables.refuse_nil_written_under_game_test!).
        def promote_place(value, test, *outer, may_stay_nil: false, owner: nil, label: nil)
          if owner
            return value if value.nil? && InstanceVariables.followed?(owner, label)

            value = InstanceVariables.promotion_target(owner, value, label, test)
          end
          return value if Steps.variable?(value)

          promoted = promote(value, test, *outer, may_stay_nil: may_stay_nil)
          Steps.variable?(promoted) ? keep_as_own(promoted) : promoted
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
          return if current.nil? || Steps.variable?(current)

          # A named field of a Struct is followed as an instance variable is.
          field = InstanceVariables.named_field?(receiver, name) ? { owner: receiver, label: :"@#{name}" } : {}
          receiver.public_send(:"#{name}=", promote_place(current, test, *outer, **field))
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

        # The same, on a name that keeps what it holds (see Value#truth). Its number is read as it
        # stands, so nil and false set it to 0, which is what each reads as.
        def store_with_truth(target, value)
          case value
          when nil then store_falsy(target, Value::NIL_HELD)
          when false then store_falsy(target, Value::FALSE_HELD)
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

        def store_falsy(target, held)
          target.store!(0)
          target.truth.store!(held)
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

        # The first line of a name that can hold nil or false as well as a number. +reached+ is a
        # line that runs after power-on (#reached_after_power_on?), where nil sets the number to 0
        # too, since the name may hold another by then.
        def start_with_truth(value, reached: false)
          own = yield(0)
          return own.tap { |variable| variable.start_truth_as_nil!(zero_number: reached) } if value.nil?

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
        # would otherwise write the variable it came from, which is somebody else's. So does one given
        # a plain number since (`differing = 0` at the top of a loop's body): the variable an outer
        # test gave the name is no longer what it holds. +name+ is the name promoted: a hidden
        # variable made for another name is that name's (`bend = out`, `out` promoted or keeping
        # a copy), and `bend = 0` under this test must not write it.
        def promote(value, test, *outer, may_stay_nil: false, name: nil)
          return value unless test.game?
          return value if outer.any?(&:game?) && Steps.variable?(value) && !handed?(value) && owned_by?(value, name)
          return value unless number_kept?(value)

          own = test.hidden_variable(:promoted, like: value.is_a?(Value) || value.is_a?(Float) ? value : nil)
          own.owner_name = name
          own.mark_boolean! if [true, false].include?(value) || value.is_a?(Condition) || (value.is_a?(Value) && value.boolean?)
          own.unwritten = value.nil?
          own.start_truth_as_nil! if may_stay_nil && value.nil?
          store_in_variable(own, value) unless value.nil?
          own
        end

        # Is +variable+ a hidden one made for +name+ (#promote, Steps.kept_answer), or one made for
        # no name in particular (a pick, a join)?
        def owned_by?(variable, name) = name.nil? || variable.owner_name.nil? || variable.owner_name == name

        def own_variable?(current) = Steps.variable?(current) && current.own_to_its_name

        # A variable of its own for the instance variable +label+, holding +value+'s number now. It
        # is made the way `hp = 10` makes one, and named after the instance variable.
        def own_copy(label, value)
          name = label.to_s.delete("@").to_sym
          own = own_variable(value) { |start| variable_for_part(name, start) }
          own.note_made_with_no_var_line
          store_in_variable(own, value)
          keep_as_own(own)
        end

        # `@a = @b` in code the game runs, where @a was only handed its variable. Copying into it
        # would change a variable that belongs to something else, and moving it would leave a line
        # that looks like a copy recording nothing. A named instance variable always has a variable
        # of its own, so in a game's own code naming it is the fix. +owner+ is the object it belongs
        # to, nil in VBlank's own files, which keep their variables with `var`.
        def refuse_move_in_game_code!(label, current, value, owner = nil)
          return unless Builder.in_use&.recording_game_code?

          bare = label.to_s.delete("@")
          fix = if owner
                  where = owner.is_a?(Builder) ? "the game block" : owner.class.name || "its class"
                  "add `game_variables :#{bare}` to #{where}"
                else
                  "give `#{label}` a variable of its own with `#{label} = var :#{bare}, 0`"
                end
          Steps.refuse_game_code!("`#{label}` holds the game variable :#{current.name}, which belongs to something " \
                                  "else, and this line gives it :#{value.name}. The game would see no change. To fix " \
                                  "this, #{fix}. Then the line copies the number.")
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
          refuse_plain_value_under_test!(name, held) if Steps.game_value?(held)

          Steps.refuse_game_code!("`#{name}` holds #{object_words(held)}, and this line changes it under a test the game " \
                            "makes as it plays. A game can keep only numbers, symbols, `true` and `false`. To fix " \
                            "this, keep a number and pick with it.")
        end

        def object_words(held)
          return held.inspect if held.is_a?(String)

          kind = held.class.name.split("::").last
          "#{kind.match?(/\A[AEIOU]/) ? 'an' : 'a'} #{kind}"
        end

        # A number, a symbol or a yes or no is something a game keeps, so the fault is not what the
        # place holds. It is that Ruby holds it: the place was not given a game variable before the
        # test, as a plain name read after its test is (#promote), so both sides of the test would
        # change the one Ruby value while the game is built.
        def refuse_plain_value_under_test!(name, held)
          Steps.refuse_game_code!("`#{name}` holds `#{held.inspect}`, which Ruby set while it built the game. This line " \
                            "changes it under a test the game makes as it plays. Ruby would make the change one " \
                            "time, and the game would not see it. To fix this, make a game variable where " \
                            "`#{name}` is first set: `#{var_line_for(name, held)}`.")
        end

        # The `var` line that gives the place +label+ a game variable starting at +held+, named after
        # the last word of the place: `hp` for `ball[:hp]`.
        def var_line_for(label, held)
          "#{label} = var :#{label.to_s.scan(/[a-z_]\w*/i).last}, #{held.inspect}"
        end

        # A number changed from a block that is a pool's `each` or a Ruby list's, which only running
        # it can tell apart. Changed while game code is recorded, a plain number would change once,
        # while building, and the game would never see it, so it becomes a game variable that starts
        # at power-on with the number the name holds. While setting up, it is returned unchanged.
        # See Rewriter#guarded_write_text.
        def variable_while_recording(owner, current, name, recording, source: nil)
          return current unless recording && whole_or_fraction?(current)

          variable_with_no_var_line(owner, name, current, source: source)
        end

        # The first line of such a name. Run while game code is recorded (in a method a game loop
        # calls), it sets the variable there, so each pass starts it afresh as Ruby's line would.
        def start_variable_while_recording(owner, value, name, recording, source: nil)
          return value unless recording && whole_or_fraction?(value)

          give_variable(variable_with_no_var_line(owner, name, value.is_a?(Float) ? 0.0 : 0, source: source), value)
        end

        # A Ruby whole number or fraction, unlike #number_kept?, which takes anything a game keeps.
        def whole_or_fraction?(value) = value.is_a?(Integer) || value.is_a?(Float)

        # A variable the author never wrote `var` for, which the out-of-memory error names.
        #
        # A game block runs on the builder, which has `var`. A part of a game is a plain class
        # that holds one, so the variable comes from the builder in use, under a name nothing has
        # taken: two parts, or two of one part, each have a local of their own, as in Ruby. The owner is
        # whatever the game's block ran on, whose own `var` may be private, as a method the block called
        # bare would be: __send__ calls it as the block would have.
        #
        # +source+ names the rewritten game block or game file the line is in. On the builder, the
        # variable is that source's own (Builder#plain_local_variable), so a local of another file
        # with the same name keeps another variable, as Ruby's locals are each their own.
        def variable_with_no_var_line(owner, name, start, source: nil)
          variable = if source && owner.is_a?(Builder) then owner.plain_local_variable(source, name, start)
                     elsif owner.respond_to?(:var, true) then owner.__send__(:var, name, start)
                     else variable_for_part(name, start)
                     end
          variable.note_made_with_no_var_line
          variable
        end

        # The same, for the line that makes the variable outside a game block: in setting up, or in
        # a method. A variable's start is the number it holds at power-on, and that is all such a
        # line needs where it runs once, before anything has changed the variable. Reached where
        # game code is recorded (the method called from a game loop, the line in the body of a loop
        # the game makes) or reached a second time, it runs after the variable has changed, so it
        # also sets the variable there, as Ruby's line would. +sets+ false leaves that to the caller.
        def variable_set_where_reached(owner, name, start, sets: true, source: nil)
          sets &&= reached_after_power_on?(owner, name, source)
          variable = variable_with_no_var_line(owner, name, start, source: source)
          give_variable(variable, start) if sets
          variable
        end

        # Does the line that makes the variable +name+ run somewhere other than once at power-on?
        # Asked before the line makes it. A line on the builder makes the one variable of its local
        # each time it runs, so a second run finds it made. A part's line makes a new variable each
        # time it runs, which nothing has changed yet.
        def reached_after_power_on?(owner, name, source)
          builder = Builder.in_use
          return false if builder.nil?
          return true if builder.recording_game_code?
          return builder.plain_local_made?(source, name) if source && owner.is_a?(Builder)

          owner.respond_to?(:var, true) && builder.variable_declared?(name)
        end

        def variable_for_part(name, start)
          builder = Builder.in_use
          Steps.refuse_game_code!("`#{name}` is changed by game code, but no game is being built. To fix this, " \
                            "make this part while a game is being built.") if builder.nil?

          builder.var(builder.reserve_free_variable_name(name), start)
        end

        # Is this something a game can keep, as opposed to an object only Ruby can hold? The one
        # answer to that, asked of the value as the line runs.
        def number_kept?(value) = value.nil? || Steps.game_value?(value) || value.is_a?(Value) || value.is_a?(Condition)

        # The first line of a name the game changes later. A number starts a variable. A variable or
        # a working-out gives it a variable of its own holding that number now, since a Ruby name
        # holds a value and never another name. Anything else stays what it is.
        #
        # The block makes the variable from the start it is handed. It is also handed whether the
        # start is the whole of what the line gives the name, which #variable_set_where_reached
        # then has to set: a variable or a working-out is set here, whatever the block does.
        def start_name(value)
          return yield(value, true) if Steps.game_value?(value)

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
      end
    end
  end
end
