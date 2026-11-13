# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # INSTANCE VARIABLES IN GAME CODE. A part of a game is a plain class, and it keeps what it
      # knows in instance variables: `@busy = 0` in `initialize`, `if @busy == 1` and `@busy = 1` in
      # the method its routine calls. Ruby runs that method once, while the game is built, so on
      # its own `if @busy == 1` would be decided then, from the 0 Ruby holds, and the game would
      # never see the line that changes it.
      #
      # A class names the instance variables that are the game's (`game_variables :busy`, in its
      # body), and only those are followed: game code reading or changing one makes it a game
      # variable, starting at power-on from the number Ruby holds then, and keeps that variable in
      # the instance variable from then on. So the read above the change asks the number the pass
      # before left. The game block names its own the same way.
      #
      # Any other instance variable stays Ruby's. One that game code both changes and reads back
      # is the bug above, so the build stops and names the fix (Uses). One changed only while
      # setting up (a counter that makes names, a count a setting-up method works out) or only read
      # by game code is left alone.
      #
      # Every instance variable a game file or block reads or writes comes through here
      # (Rewriter#instance_variable_read_text, Writes.write and Writes.change with +owner+);
      # VBlank's own files are rewritten without this. An instance variable of a class itself
      # (`@cache` in `def self.table`) is never followed: nothing can name it.
      module InstanceVariables
        # The constant a class keeps the instance variables it names in, as `:@busy`.
        NAMES_CONSTANT = :VBLANK_GAME_VARIABLES

        # What a followed instance variable can hold as Ruby and start a game variable from.
        STARTS = [Integer, Float, TrueClass, FalseClass, Symbol].freeze

        module_function

        # The constant a class keeps the variable names it chose in, as `{ :@states => :lit_state }`.
        CHOSEN_NAMES_CONSTANT = :VBLANK_GAME_VARIABLE_NAMES

        # The constant a class keeps the instance variables it marks `saved: false` in, as `:@busy`.
        UNSAVED_NAMES_CONSTANT = :VBLANK_UNSAVED_GAME_VARIABLES

        # `game_variables :busy, :seed`, written in a class's body, a module's, or the game block
        # (+owner+ is whichever ran it). The rewrite turns the call into this one. A Hash among
        # +names+, or the keywords left in +chosen+ (`game_variables states: :lit_state`), names an
        # instance variable and gives its game variable a name of the game's own, which a profile
        # and a test read it by.
        #
        # `saved: false` marks every instance variable on the line as scratch: a save record
        # never keeps one, and `saves_keep_everything` passes it over. That is what a name starting
        # with _ says for a `var`, without making the game write a second name for each.
        def name_game_variables(owner, *names, saved: true, **chosen_by_keyword)
          refuse_saved_not_true_or_false!(saved)
          names += [chosen_by_keyword] unless chosen_by_keyword.empty?
          labels, chosen = labels_and_chosen_names(names)
          case owner
          when Builder then owner.instance_variable_uses.name_on_builder(labels, chosen, unsaved: saved ? [] : labels)
          when Module
            name_in_module(owner, labels)
            name_in_module(owner, labels, constant: UNSAVED_NAMES_CONSTANT) unless saved
            store_chosen_names(owner, chosen) unless chosen.empty?
          else refuse_named_outside_class!(owner)
          end
          nil
        end

        # +names+ as instance variable labels, and the names the game chose for some of them.
        def labels_and_chosen_names(names)
          labels = []
          chosen = {}
          names.each do |name|
            next labels << instance_variable_label(name) unless name.is_a?(Hash)

            name.each do |instance_variable, variable_name|
              label = instance_variable_label(instance_variable)
              labels << label
              chosen[label] = chosen_variable_name!(label, variable_name)
            end
          end
          [labels, chosen]
        end

        def refuse_saved_not_true_or_false!(saved)
          return if [true, false].include?(saved)

          raise Refused, "`game_variables` takes `saved: false` or `saved: true`, and it was given " \
                         "`saved: #{saved.inspect}`. If a save never keeps these variables, write `saved: " \
                         "false`. To give `@saved` a name of its own, write `game_variables({ saved: " \
                         "#{saved.inspect} })`.#{Messages::AuthorSource.at_author_line}"
        end

        # The name +label+'s game variable is given, `:lit_state` from `states: :lit_state`, refused
        # unless it is a word a variable can be named.
        def chosen_variable_name!(label, variable_name)
          word = variable_name.to_s if variable_name.is_a?(Symbol) || variable_name.is_a?(String)
          return word.to_sym if word&.match?(/\A[a-z_][a-z0-9_]*\z/)

          raise Refused, "`game_variables` gives `#{label}` the variable name #{variable_name.inspect}. A variable " \
                         "name is a word of small letters, digits and `_`. To fix this, give a name like " \
                         "`#{label.to_s.delete_prefix('@')}: :lit_state`." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # The names a class chose, kept as its names are (#name_in_module).
        def store_chosen_names(owner, chosen)
          named = owner.const_defined?(CHOSEN_NAMES_CONSTANT, false) ? owner.const_get(CHOSEN_NAMES_CONSTANT, false) : {}
          merged = merge_chosen_names(named, chosen)
          return if merged == named

          owner.class_eval { remove_const(CHOSEN_NAMES_CONSTANT) } if owner.const_defined?(CHOSEN_NAMES_CONSTANT, false)
          owner.const_set(CHOSEN_NAMES_CONSTANT, Ractor.make_shareable(merged))
        end

        # +named+ with +chosen+ added. An instance variable keeps one name, and two of them never
        # share one: each would find the other's variable taken.
        def merge_chosen_names(named, chosen)
          merged = named.merge(chosen) do |label, before, now|
            refuse_two_names!(label, before, now) unless before == now
            now
          end
          refuse_shared_names!(merged)
          merged
        end

        def refuse_two_names!(label, before, now)
          raise Refused, "`game_variables` gives `#{label}` the variable name :#{now}, and an earlier line gave it " \
                         ":#{before}. To fix this, give it one name.#{Messages::AuthorSource.at_author_line}"
        end

        def refuse_shared_names!(chosen)
          chosen.group_by { |_, name| name }.each do |name, pairs|
            next if pairs.length < 2

            raise Refused, "`game_variables` gives #{pairs.map { |label, _| "`#{label}`" }.join(' and ')} the same " \
                           "variable name, :#{name}. To fix this, give each one a name of its own." \
                           "#{Messages::AuthorSource.at_author_line}"
          end
        end

        # The names +holder+ and the classes and modules it is made from chose. Where two chose for
        # one instance variable, the nearest wins: a subclass can name its parent's again.
        def chosen_names_of(holder)
          holder.ancestors.reverse.each_with_object({}) do |each_module, chosen|
            chosen.merge!(each_module.const_get(CHOSEN_NAMES_CONSTANT, false)) if each_module.const_defined?(CHOSEN_NAMES_CONSTANT, false)
          end
        end

        # The variable name for +owner+'s +label+: +name+, or a free one after it (`tilt_busy_2`)
        # for a second object of one class. A name the game chose is refused where something else
        # has the variable already, a `var` line or another class's choice, since a test reading it
        # would read the wrong one.
        def free_name_for(owner, label, name)
          builder = Builder.in_use
          uses = builder.instance_variable_uses
          free = builder.free_variable_name(name)
          if free != name && uses.chosen_name(owner, label) && !uses.made_for?(name, owner, label)
            refuse_chosen_name_taken!(label, name)
          end
          uses.note_made_for(name, owner, label)
          free
        end

        def refuse_chosen_name_taken!(label, name)
          raise Refused, "`game_variables` gives `#{label}` the variable name :#{name}, and another variable of the " \
                         "game has that name. To fix this, give `#{label}` a name that no other variable has." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # `:busy` as `:@busy`.
        def instance_variable_label(name)
          unless name.is_a?(Symbol) || name.is_a?(String)
            raise Refused, "`game_variables` takes the names of instance variables, like `game_variables :busy`. " \
                           "It was given #{name.inspect}.#{Messages::AuthorSource.at_author_line}"
          end

          :"@#{name.to_s.delete_prefix('@')}"
        end

        # A class keeps its names in a constant, which every Ractor that builds a game can read. A
        # second line, in the body or in the class reopened, adds its names, as a second
        # `attr_reader` does; the same line run again (a file loaded twice) changes nothing.
        # The marks `saved: false` sets are kept the same way, in a constant of their own.
        def name_in_module(owner, labels, constant: NAMES_CONSTANT)
          if owner.const_defined?(constant, false)
            named = owner.const_get(constant, false)
            labels = named | labels
            return if labels == named

            owner.class_eval { remove_const(constant) }
          end

          owner.const_set(constant, Ractor.make_shareable(labels.uniq))
        end

        # `game_variables` in a method, `def self.setup` above all: there it would run on whatever the
        # method runs on, naming nothing a game reads.
        def refuse_named_in_method!
          raise Refused, "`game_variables` names the instance variables of a class's objects, so it goes in the " \
                         "class's body. Here it is in a method. To fix this, move it to the line after `class`." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # `game_variables` reached as a real method: its file came in with `require` or
        # `require_relative`, which no rewrite reads, so its class's instance variables would never
        # be followed (Module#game_variables, below).
        def refuse_unread_file!(at)
          name = File.basename(at.path, ".rb")
          raise Refused, "`game_variables` is in `#{File.basename(at.path)}`, which came in with `require` or " \
                         "`require_relative`, so VBlank did not read it as game code. To fix this, load it with " \
                         "`VBlank.require_game_file \"#{name}\"`. (at #{File.basename(at.path)}:#{at.lineno})"
        end

        # `attr_accessor(*LEVELS)` in a class of a game file: each reader and writer made to read and
        # write as a line of game code does, as Rewriter#attribute_method_text writes them out for
        # names written as symbols. Written as source, since a method made from a block cannot be
        # called from another Ractor. The answer is the methods' names, as Ruby's own call gives.
        def attribute_methods(owner, kind, names)
          names.flat_map do |name|
            raise NameError, "invalid attribute name `#{name}'" unless name.to_s.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

            ivar = "@#{name}"
            made = []
            if %i[attr_reader attr_accessor].include?(kind)
              owner.class_eval("def #{name} = ::VBlank::DSL::PlainRuby::InstanceVariables.read_value(self, #{ivar}, " \
                               ":#{ivar}) { |given| #{ivar} = given }", __FILE__, __LINE__ - 1)
              made << name.to_sym
            end
            if %i[attr_writer attr_accessor].include?(kind)
              owner.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
                def #{name}=(written)
                  current = ::VBlank::DSL::PlainRuby::InstanceVariables.value_before_write(self, #{ivar}, :#{ivar}) { |given| #{ivar} = given }
                  #{ivar} = ::VBlank::DSL::PlainRuby::Writes.write(current, written, [], :#{ivar}, moves: true, owner: self) { |value| value }
                end
              RUBY
              made << :"#{name}="
            end
            made
          end
        end

        def refuse_named_outside_class!(owner)
          raise Refused, "`game_variables` names the instance variables of a class, so it goes in the class's body. " \
                         "Here it is called on #{Writes.object_words(owner)}. To fix this, move it to the line after " \
                         "`class`.#{Messages::AuthorSource.at_author_line}"
        end

        # The instance variables +holder+ and the classes and modules it is made from name (or, given
        # UNSAVED_NAMES_CONSTANT, mark `saved: false`).
        def names_in_module(holder, constant: NAMES_CONSTANT)
          holder.ancestors.flat_map do |each_module|
            each_module.const_defined?(constant, false) ? each_module.const_get(constant, false) : []
          end
        end

        # A line of game code reads the instance variable +label+ of +owner+, which holds +current+.
        # A named one becomes its game variable here, handed to the block to keep, and that is the
        # answer. +in_text+ is a read put into a String or a Symbol, which can only be Ruby's.
        def read_value(owner, current, label, in_text: false)
          uses = uses_while_recording(owner)
          return current unless uses

          if uses.named?(owner, label)
            variable = game_variable_of(owner, current, label)
            yield variable unless variable.equal?(current)
            return variable
          end
          uses.note_read(owner, label, current) unless in_text
          current
        end

        # What +owner+'s +label+ holds as a line of game code is about to write it: a named one's
        # game variable, made here and handed to the block to keep. This is not a read the game
        # makes, so nothing is noted. It runs before the line works out what it writes, so a write
        # that reads the instance variable too (`@seed = @seed * 5`) finds the one variable.
        def value_before_write(owner, current, label)
          uses = uses_while_recording(owner)
          return current unless uses&.named?(owner, label) && !current.nil?

          variable = game_variable_of(owner, current, label)
          yield variable unless variable.equal?(current)
          variable
        end

        # Is +label+ of +owner+ followed on the line running now? A line that reads and writes in
        # one (`@busy ||= 1`) is written out the long way only then.
        def followed?(owner, label) = uses_while_recording(owner)&.named?(owner, label) || false

        # What Writes.write writes to, where +owner+'s +label+ holds +current+ and a line of game code
        # gives it +value+: a named one's game variable, made here if it held nil; anything else as
        # it is, the write noted (Uses#note_change). +starting+ is a line of `initialize`, which
        # gives the object its start, even where game code makes the object: no change is noted.
        #
        # A named one is never handed another's variable, while setting up either: given a game
        # variable or a working-out while it holds nothing, it gets a variable of its own, which
        # the write then sets to that number (`@held = @states[0]`, `@phase = start_phase`).
        def write_target(owner, current, value, label, starting: false)
          uses = uses_while_recording(owner)
          return own_variable_while_setting_up(owner, current, value, label) unless uses

          unless uses.named?(owner, label)
            uses.note_change(owner, label, current, value, operator: false) unless starting
            return current
          end
          return game_variable_of(owner, current, label) unless current.nil?
          return current unless Writes.number_kept?(value) && !value.nil?

          variable_starting_like(owner, label, value)
        end

        def own_variable_while_setting_up(owner, current, value, label)
          builder = Builder.in_use
          return current unless current.nil? && (value.is_a?(Value) || value.is_a?(Condition))
          return current unless builder && !owner.is_a?(Module) && builder.instance_variable_uses.named?(owner, label)

          variable_starting_like(owner, label, value)
        end

        # The same for `@busy += 1`, which reads it as well.
        def change_target(owner, current, label, starting: false)
          uses = uses_while_recording(owner)
          return current unless uses
          return game_variable_of(owner, current, label) if uses.named?(owner, label)

          uses.note_change(owner, label, current, current, operator: true) unless starting
          current
        end

        # The same for a change under a test the game makes, about to be given a hidden variable
        # (Writes.promote_place).
        def promotion_target(owner, current, label, test)
          uses = uses_while_recording(owner)
          return current unless uses
          return game_variable_of(owner, current, label) if uses.named?(owner, label)

          uses.note_change(owner, label, current, current, operator: false) if test.game?
          current
        end

        # A line of game code gives +owner+'s named +label+, still holding nil, a number under a test
        # the game makes (one of +tests+). On a pass where that test fails it would still hold nil,
        # and a game variable cannot, so the build stops here. The same line under a test decided
        # while building alone gives it its first number as usual (#write_target).
        def refuse_nil_written_under_game_test!(owner, current, label, tests)
          return unless current.nil? && tests.any?(&:game?)
          return unless uses_while_recording(owner)&.named?(owner, label)

          refuse_named_object!(label, current)
        end

        # The builder's record of instance variables, while it records game code.
        def uses_while_recording(owner)
          builder = Builder.in_use
          return unless builder&.recording_game_code? && !owner.is_a?(Module)

          builder.instance_variable_uses
        end

        # The game variable a named instance variable holding +current+ is: made now from a number
        # it still holds as Ruby, or the one it holds already.
        def game_variable_of(owner, current, label)
          return current if Steps.variable?(current) || current.is_a?(Condition)
          return make_variable(owner, label, current) if STARTS.any? { |kind| current.is_a?(kind) }
          return game_variables_in(owner, label, current) if numbers_collection?(current)

          refuse_named_object!(label, current)
        end

        # A NAMED VALUE IS THE GAME'S FROM ITS FIRST NUMBER. The line that first gives a named
        # instance variable (or a named field) a number, while setting up or anywhere else, makes its
        # game variable, starting at power-on from that number as `var` would. From then on it holds
        # the variable, so every read is the game's, wherever it is recorded: in another routine, in a
        # block another part calls later, through `attr_reader`, or in a part it was handed to as that
        # part was made. A Hash or an Array of numbers makes a variable for each key.
        #
        # Nil where this is not such a line: no builder, a name not on the class's list, a place
        # that holds something already, or a value no game variable starts from. Nothing unnamed
        # comes here.
        def first_variable(owner, current, value, label)
          builder = Builder.in_use
          return unless current.nil? && builder && !owner.is_a?(Module)
          return unless builder.instance_variable_uses.named?(owner, label)
          return game_variables_in(owner, label, value) if numbers_collection?(value)
          return unless STARTS.any? { |kind| value.is_a?(kind) }

          make_variable(owner, label, value)
        end

        # Does a first number given in game code also set the variable where the line runs? Not
        # where `initialize` gives it (+starting+): that part is made once, as its routine is recorded
        # (`screen = FadedScreen.new(...)` in `scene :copyright do`), and its number is the start.
        # Anywhere else in game code the line runs on every pass, as Ruby's would.
        def first_number_set_where_reached?(starting) = Builder.in_use.recording_game_code? && !starting

        # A Hash or an Array of numbers (`@tilt_counters = { left: 0, right: 0 }`), or one already
        # made of game variables here.
        def numbers_collection?(held)
          values = held.is_a?(Hash) ? held.values : held
          return false unless (held.is_a?(Hash) || held.is_a?(Array)) && !values.empty?

          values.all? { |value| Steps.variable?(value) || STARTS.any? { |kind| value.is_a?(kind) } }
        end

        # A NAMED HASH OR ARRAY OF NUMBERS is a game variable for each key, each starting from the
        # number Ruby holds there and named after the key (`tilt_counters_left`). The game reads and
        # changes one at a key known while building (`@tilt_counters[side] += 1`, with `side` a
        # symbol of a Ruby loop). A key the game works out has no slot to name, so the copy refuses
        # one (KeyedVariables); it is frozen, so a key it does not have is refused as a misspelling.
        def game_variables_in(owner, label, held)
          return held if held.is_a?(KeyedVariables)

          base = variable_name(owner, label)
          if held.is_a?(Hash)
            KeyedHash[held.map { |key, value| [key, element_variable(owner, label, base, key, value)] }].freeze
          else
            KeyedArray.new(held.each_with_index.map { |value, index| element_variable(owner, label, base, index, value) }).freeze
          end
        end

        def element_variable(owner, label, base, key, start)
          return start if Steps.variable?(start)

          builder = Builder.in_use
          suffix = key.is_a?(Symbol) || key.is_a?(Integer) || key.is_a?(String) ? key.to_s : "key"
          variable = builder.var(free_name_for(owner, label, :"#{base}_#{suffix}"), start)
          note_made_variable(builder, variable, owner, label)
        end

        # What a named Hash or Array of numbers becomes: its slots are game variables, taken at keys
        # Ruby holds while building.
        module KeyedVariables
          def [](*keys)
            if keys.any?(Value)
              Steps.refuse_game_code!("This Hash or Array holds game variables, and this line takes one at a key " \
                                      "that is worked out as the game plays. Ruby finds a slot while it builds the " \
                                      "game, so it cannot find this one. To fix this, use a key known while " \
                                      "building, like a symbol from a Ruby loop (`SIDES.each do |side|`), or keep " \
                                      "the numbers in a game's own list.")
            end

            super
          end
        end

        class KeyedHash < Hash
          include KeyedVariables
        end

        class KeyedArray < Array
          include KeyedVariables
        end

        # `Struct.new(:count, :step)` in game code: the class it makes, its readers and writers
        # written again to come through #read_field and #write_field, which follow a field the class
        # names (`game_variables :count` in the block of `Struct.new`, or in a class made from one)
        # as a named instance variable is, and leave every other field to Ruby. A field is kept as
        # `:@count`, the label its instance variable would have, so one list of names serves. Written
        # as source, since a method made from a block cannot be called from another Ractor.
        def followed_struct(made)
          return made unless made.is_a?(Class) && made < Struct

          accessors = Module.new
          # Struct's own `initialize` sets the fields without their writers, so the named ones are
          # made game variables after it, as a named instance variable is at its first number.
          accessors.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def initialize(...)
              super
              ::VBlank::DSL::PlainRuby::InstanceVariables.start_named_fields(self)
            end
          RUBY
          made.members.each do |field|
            accessors.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{field} = ::VBlank::DSL::PlainRuby::InstanceVariables.read_field(self, :#{field})
              def #{field}=(given)
                ::VBlank::DSL::PlainRuby::InstanceVariables.write_field(self, :#{field}, given)
              end
            RUBY
          end
          made.prepend(accessors)
          made
        end

        # Is +field+ of +holder+, a Struct, one its class names?
        def named_field?(holder, field)
          holder.is_a?(Struct) && names_in_module(holder.class).include?(:"@#{field}")
        end

        def read_field(holder, field)
          return holder[field] unless named_field?(holder, field)

          read_value(holder, holder[field], :"@#{field}") { |variable| holder[field] = variable }
        end

        def write_field(holder, field, given)
          return holder[field] = given unless named_field?(holder, field)

          label = :"@#{field}"
          current = field_before_write(holder, field)
          holder[field] = Writes.write(current, given, [], label, moves: true, owner: holder) { |value| value }
        end

        # What Writes.attribute finds in a named field about to be written: as #value_before_write.
        def field_before_write(holder, field)
          value_before_write(holder, holder[field], :"@#{field}") { |variable| holder[field] = variable }
        end

        # Each named field of +holder+, just made, given its game variable (#first_variable).
        def start_named_fields(holder)
          holder.members.each do |field|
            next unless named_field?(holder, field)

            current = holder[field]
            made = first_variable(holder, nil, current, :"@#{field}")
            # Made from a game variable or a working-out: a variable of its own, holding that number.
            if made.nil? && Builder.in_use && (current.is_a?(Value) || current.is_a?(Condition))
              made = variable_starting_like(holder, :"@#{field}", current)
              Writes.store_in_variable(made, current)
            end
            holder[field] = made if made
          end
        end

        def make_variable(owner, label, start)
          builder = Builder.in_use
          variable = builder.var(free_name_for(owner, label, variable_name(owner, label)), start)
          note_made_variable(builder, variable, owner, label)
        end

        # A game variable just made for +owner+'s +label+: noted as made with no `var` line, and as
        # unsaved where the line naming it set `saved: false`. Kept as the instance variable's own.
        def note_made_variable(builder, variable, owner, label)
          variable.note_made_with_no_var_line
          variable.note_unsaved if builder.instance_variable_uses.marked_unsaved?(owner, label)
          Writes.keep_as_own(variable)
        end

        # One holding nil, first given +value+ in game code: a variable of +value+'s kind, which
        # the write then sets, as a name first set in game code is.
        def variable_starting_like(owner, label, value)
          return Writes.own_variable(value) { |start| make_variable(owner, label, start) } if value.is_a?(Value)

          start = value.is_a?(Condition) ? false : value
          start = start.is_a?(Float) ? 0.0 : 0 if start.is_a?(Numeric)
          make_variable(owner, label, start)
        end

        # The name a profile and a test read the variable by: `tilt_busy` for `@busy` of a Tilt, so
        # it cannot meet a name the game gives a variable of its own, and `score` for the game
        # block's `@score`. An object of a class with no name is a `part`'s. A name the class chose
        # (`game_variables busy: :tilt_wait`) is taken as it is.
        def variable_name(owner, label)
          chosen = Builder.in_use.instance_variable_uses.chosen_name(owner, label)
          return chosen if chosen

          bare = label.to_s.delete_prefix("@")
          return bare.to_sym if owner.is_a?(Builder)

          class_name = owner.class.name.to_s.split("::").last || "Part"
          :"#{class_name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase}_#{bare}"
        end

        def refuse_named_object!(label, held)
          if held.nil?
            raise Refused, "`#{label}` is a game variable, and it holds `nil` here. A game variable starts with a " \
                           "number. To fix this, give `#{label}` a number, `true` or `false` where it is first set, " \
                           "like `#{label} = 0`.#{Messages::AuthorSource.at_author_line}"
          end

          raise Refused, "`#{label}` is a game variable, and it holds #{Writes.object_words(held)} here. A game " \
                         "variable keeps only a number, a symbol, `true` or `false`. To fix this, keep the object " \
                         "in another instance variable, or take `#{label}` out of `game_variables`." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # WHAT GAME CODE DID TO THE INSTANCE VARIABLES NOBODY NAMED, one build's worth, kept by the
        # builder. A plain one game code reads and changes is the silent bug a name fixes:
        #
        # - read before game code changes it (`if @busy == 1` above `@busy = 1`): the read was
        #   decided from the number Ruby held before the change, where the game reads the number
        #   the pass before left. Refused at the change.
        # - read after a change that worked from Ruby's number (`@ticks += 1`, then `if @ticks >
        #   60`): the change was made once, while building, so the read is too. Refused at the read,
        #   naming the change.
        # - read in another routine than the one whose line gave it a number: the game can run the
        #   two in either order. Refused at the read, naming the change.
        #
        # A read after its own routine gave it a number outright (`@rows = 2`, then `@rows.times`)
        # is the number that line gives on every pass, so it is left alone. So is a read put into a
        # String or a Symbol, which is Ruby's by nature, and a read of nil (`return if @made`):
        # naming it would not help, since a game variable cannot start as nil. So is a write in
        # `initialize`, which starts the object, wherever it is made (+starting+ below), and a
        # `true` or `false` (#plain_number?).
        class Uses
          # One instance variable of one object, as the build goes on: whether game code read it
          # before changing it, the line that first changed it, the line of a change worked out from
          # Ruby's own number that nothing has given a number outright since, and the routine whose
          # line last gave it a number. A Struct, since each field is set as the build reaches it.
          Use = Struct.new(:read_before_change, :changed_at, :changed_from_ruby_at, :given_in)

          TRACKED = [Integer, Float, Symbol].freeze # What a plain instance variable is noted holding

          def initialize
            @named_on_builder = Set.new
            @unsaved_on_builder = Set.new
            @chosen_on_builder = {}
            @names_by_class = {}
            @unsaved_by_class = {}
            @chosen_by_class = {}
            @makers_by_name = {}
            @uses = {}.compare_by_identity
          end

          def name_on_builder(labels, chosen = {}, unsaved: [])
            @named_on_builder.merge(labels)
            @unsaved_on_builder.merge(unsaved)
            @chosen_on_builder = InstanceVariables.merge_chosen_names(@chosen_on_builder, chosen)
          end

          # Did a line naming +owner+'s +label+ (in its class or an ancestor) set `saved: false`?
          def marked_unsaved?(owner, label)
            return @unsaved_on_builder.include?(label) if owner.is_a?(Builder)

            (@unsaved_by_class[owner.class] ||=
               InstanceVariables.names_in_module(owner.class, constant: UNSAVED_NAMES_CONSTANT)).include?(label)
          end

          # Was variable name +name+ first made for +label+ of an object of +owner+'s class (or the
          # game block)? A second object of one class takes the next free name after it.
          def made_for?(name, owner, label) = @makers_by_name[name] == maker(owner, label)

          def note_made_for(name, owner, label) = @makers_by_name[name] ||= maker(owner, label)

          def named?(owner, label)
            return @named_on_builder.include?(label) if owner.is_a?(Builder)

            (@names_by_class[owner.class] ||= InstanceVariables.names_in_module(owner.class)).include?(label)
          end

          # The variable name +owner+'s class (or the game block) chose for +label+, or nil.
          def chosen_name(owner, label)
            return @chosen_on_builder[label] if owner.is_a?(Builder)

            (@chosen_by_class[owner.class] ||= InstanceVariables.chosen_names_of(owner.class))[label]
          end

          def note_read(owner, label, current)
            return unless plain_number?(current)

            use = use_of(owner, label)
            refuse_unnamed_change!(owner, label, use.changed_from_ruby_at) if use.changed_from_ruby_at
            if use.changed_at && !use.given_in.equal?(Builder.in_use.recorded_routine_body)
              refuse_unnamed_change!(owner, label, use.changed_at)
            end
            use.read_before_change = true unless use.changed_at
          end

          # A line of game code gives +label+ +value+, or changes it with an operator (+operator+)
          # from what it holds. Only a plain number held is the game's to lose; nil counts, given a
          # number.
          def note_change(owner, label, current, value, operator:)
            return unless (current.nil? || plain_number?(current)) && plain_number?(value)

            use = use_of(owner, label)
            here = Messages::AuthorSource.author_file_and_line
            refuse_unnamed_change!(owner, label, here) if use.read_before_change
            use.changed_from_ruby_at = operator && (use.changed_from_ruby_at || (here unless use.changed_at))
            use.given_in = Builder.in_use.recorded_routine_body
            use.changed_at ||= here
          end

          private

          # A number or a symbol: what a game keeps and a line of game code can mean to change.
          # `true` and `false` are left out. A plain one in game code is a flag the build keeps for
          # itself, as a part's `plan unless @planned` is, and nothing the game runs can read it:
          # a test on it is Ruby's, decided while building.
          def plain_number?(value) = TRACKED.any? { |kind| value.is_a?(kind) }

          # Who a variable name is made for: the game block, or the class or module that chose the
          # name (so the objects of two subclasses share its run of names), else the object's class.
          def maker(owner, label)
            return [Builder, label] if owner.is_a?(Builder)

            chooser = owner.class.ancestors.find do |each_module|
              each_module.const_defined?(CHOSEN_NAMES_CONSTANT, false) &&
                each_module.const_get(CHOSEN_NAMES_CONSTANT, false).key?(label)
            end
            [chooser || owner.class, label]
          end

          def use_of(owner, label) = (@uses[owner] ||= {})[label] ||= Use.new(false, nil, nil, nil)

          def refuse_unnamed_change!(owner, label, changed_at)
            name = label.to_s.delete_prefix("@")
            where = owner.is_a?(Builder) ? "the game block" : owner.class.name || "its class"
            raise Refused, "`#{label}` is changed while the game plays, and game code reads it. `#{label}` is a plain " \
                           "Ruby value, so the game does not see the change. It keeps the number that Ruby gave it " \
                           "while Ruby built the game. To fix this, add `game_variables :#{name}` to #{where}." \
                           "#{" (changed at #{changed_at})" if changed_at}"
          end
        end
      end
    end
  end
end

# `game_variables` in a class body is rewritten into a call to InstanceVariables in every file VBlank
# reads as game code, so the method itself is only ever reached from a file that came in some other
# way. Without it that file stops with a NoMethodError naming no fix; this names the fix instead.
class Module
  private def game_variables(*, **) = VBlank::DSL::PlainRuby::InstanceVariables.refuse_unread_file!(caller_locations(1, 1).first)
end
