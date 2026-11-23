# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # Instance variables in game code. A part of a game is a plain class, and it keeps what it
      # knows in instance variables: `@busy = 0` in `initialize`, `if @busy == 1` and `@busy = 1` in
      # the method its routine calls. Ruby runs that method once, while the game is built, so on
      # its own `if @busy == 1` would be decided then, from the 0 Ruby holds, and the game would
      # never see the line that changes it.
      #
      # Two kinds are followed. One a class names (`game_variables :busy`, in its body) is the
      # game's from its first number. One the source shows game code may change (#mark_changing:
      # `@busy = 1 - @busy` anywhere, `@busy = 1` in a game verb's block) is the game's from the
      # first line of game code that reads or changes it. Either way the line makes a game
      # variable, starting at power-on from the number Ruby holds then, and keeps that variable in
      # the instance variable from then on. So the read above the change asks the number the pass
      # before left. The game block's own work the same way.
      #
      # The marks are made from the source, so each is known before game code first reads the
      # instance variable, in whatever order the routines are recorded: the build runs once.
      #
      # Any other instance variable stays Ruby's. One that game code both changes and reads back,
      # where the source does not show the change, is the bug above, so the build stops and names
      # the fix (Uses). One changed only while setting up (a counter that makes names, a count a
      # setting-up method works out) or only read by game code is left alone.
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

        # The constant a class keeps in the named instance variables whose Array of numbers is a
        # list the game keeps (#keep_arrays_as_lists), as `:@counts`.
        LISTS_CONSTANT = :VBLANK_GAME_VARIABLE_LISTS

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
        #
        # The mark must come before the variable's first number, since that line makes the variable
        # (#note_made_variable): a mark after it is refused (Uses#refuse_late_unsaved_mark!).
        def name_game_variables(owner, *names, saved: true, **chosen_by_keyword)
          refuse_saved_not_true_or_false!(saved)
          names += [chosen_by_keyword] unless chosen_by_keyword.empty?
          labels, chosen = labels_and_chosen_names(names)
          refuse_unsaved_naming_nothing! if !saved && labels.empty?
          uses = owner.is_a?(Builder) ? owner.instance_variable_uses : Builder.in_use&.instance_variable_uses
          uses&.refuse_late_unsaved_mark!(owner, labels) unless saved
          case owner
          when Builder then uses.name_on_builder(labels, chosen, unsaved: saved ? [] : labels)
          when Module
            name_in_module(owner, labels)
            name_in_module(owner, labels, constant: UNSAVED_NAMES_CONSTANT) unless saved
            store_chosen_names(owner, chosen) unless chosen.empty?
            # A class reopened while a game builds: the build's cache of class names is out of date.
            uses&.clear_class_name_cache
          else refuse_named_outside_class!(owner)
          end
          nil
        end

        # Of the instance variables a `game_variables` line names, +labels+ are read or written by
        # the code around it at an index that may be worked out as the game plays
        # (LocalNames#instance_variables_at_worked_out_keys). An Array of numbers one of them is
        # given becomes a list the game keeps (#first_variable), not a variable for each index,
        # since only a list can be read at an index the game works out. One read only at indexes
        # known while building stays a variable for each.
        def keep_arrays_as_lists(owner, labels)
          case owner
          when Builder then owner.instance_variable_uses.keep_arrays_as_lists_on_builder(labels)
          when Module then name_in_module(owner, labels, constant: LISTS_CONSTANT)
          end
          nil
        end

        # The constant a class keeps the instance variables its code may change as the game plays
        # in (#mark_changing), as `:@ticks`.
        CHANGING_CONSTANT = :VBLANK_CHANGING_INSTANCE_VARIABLES

        # +labels+ are instance variables of +owner+ (a class or module, or the game block's
        # builder) that its code may change as the game plays: the rewrite read a line that works
        # one out from what it holds, or gives one a value in a game verb's block
        # (LocalNames#changing_instance_variables). Each stays Ruby's while the game is set up, and
        # becomes a game variable where game code first reads or changes it (Uses#followed?), as if
        # `game_variables` named it. Marked from the source, so the mark is there before game code
        # reads any of them, however the methods that read and change them are ordered.
        #
        # +attributes+ are the game block's: the attributes it may change on any object through a
        # writer (LocalNames#changing_attributes). A game file's are kept for every build
        # (#record_changing_attributes).
        def mark_changing(owner, labels, attributes: [])
          case owner
          when Builder then owner.instance_variable_uses.mark_changing_on_builder(labels, attributes)
          when Module
            name_in_module(owner, labels, constant: CHANGING_CONSTANT)
            Builder.in_use&.instance_variable_uses&.clear_class_name_cache
          end
          nil
        end

        # The attributes game files may change through a writer (LocalNames#changing_attributes),
        # as `:level`. Files are loaded in the main Ractor, before any game is built, and every
        # Ractor reads the same names, as CallChanges.game_method_names.
        def self.changing_attributes_in_files = @changing_attributes_in_files || Set.new.freeze

        def self.record_changing_attributes(names)
          return if names.empty? || Ractor.current != Ractor.main

          @changing_attributes_in_files = Ractor.make_shareable(changing_attributes_in_files | names)
        end

        def refuse_unsaved_naming_nothing!
          raise Refused, "`game_variables saved: false` names no instance variable, so it marks nothing. To fix " \
                         "this, name the variables on the same line, like `game_variables :busy, saved: false`." \
                         "#{Messages::AuthorSource.at_author_line}"
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
        #
        # One its code may change, which no line names, is made where game code first reads or
        # changes it, and the objects of a class can be reached in any order there. So its name
        # follows the order they were made in (Uses#made_name), as a named one's does by being made
        # in `initialize`: a save made before finds each number under the name it had.
        def free_name_for(owner, label, name)
          builder = Builder.in_use
          uses = builder.instance_variable_uses
          name = uses.made_name(owner, label, name)
          free = builder.reserve_free_variable_name(name)
          if free != name && uses.chosen_name(owner, label) && !uses.made_for?(name, owner, label)
            refuse_chosen_name_taken!(label, name)
          end
          uses.note_made_for(name, owner, label)
          uses.note_part_variable(free, owner, label)
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
          current = current_or_ruby_number(current) { |number| yield number }
          uses = uses_while_recording(owner)
          return current unless uses

          if uses.followed?(owner, label, current)
            variable = game_variable_of(owner, current, label)
            yield variable unless variable.equal?(current)
            return variable
          end
          unless in_text
            uses.note_read(owner, label, current)
            uses.note_flag_read(owner, label, current) if Uses::FLAGS.include?(current)
          end
          current
        end

        # What +owner+'s +label+ holds as a line of game code is about to write it: a named one's
        # game variable, made here and handed to the block to keep. This is not a read the game
        # makes, so nothing is noted. It runs before the line works out what it writes, so a write
        # that reads the instance variable too (`@seed = @seed * 5`) finds the one variable.
        def value_before_write(owner, current, label)
          current = current_or_ruby_number(current) { |number| yield number }
          uses = uses_while_recording(owner)
          return current unless uses&.followed?(owner, label, current) && !current.nil?

          variable = game_variable_of(owner, current, label)
          yield variable unless variable.equal?(current)
          variable
        end

        # Is +label+ of +owner+, holding +current+, followed on the line running now? A line that
        # reads and writes in one (`@busy ||= 1`) is written out the long way only then.
        def followed?(owner, current, label)
          uses_while_recording(owner)&.followed?(owner, label, current_or_ruby_number(current) {}) || false
        end

        # What Writes.write writes to, where +owner+'s +label+ holds +current+ and a line of game code
        # gives it +value+: a named one's game variable, made here if it held nil; anything else as
        # it is, the write noted (Uses#note_change). +starting+ is a line of `initialize`, which
        # gives the object its start, even where game code makes the object: no change is noted.
        #
        # A named one is never handed another's variable, while setting up either: given a game
        # variable or a working-out while it holds nothing, it gets a variable of its own, which
        # the write then sets to that number (`@held = @states[0]`, `@phase = start_phase`).
        def write_target(owner, current, value, label, starting: false)
          current = current_or_ruby_number(current) {}
          uses = uses_while_recording(owner)
          return own_variable_while_setting_up(owner, current, value, label) unless uses

          unless uses.followed?(owner, label, current) || game_number_given?(current, value, starting)
            uses.note_change(owner, label, current, value, operator: false) unless starting
            return current
          end
          return game_variable_of(owner, current, label) unless current.nil?
          return current unless Writes.number_kept?(value) && !value.nil?

          variable_starting_like(owner, label, value)
        end

        # Does a line of game code give an instance variable that holds a plain number, or nothing,
        # a game number (`@shown = @ticks`)? Ruby copies a number, so it must keep a variable of its
        # own holding that number: sharing the other's variable, it would change when the other
        # does. A line of `initialize` is left as it is: a part handed a variable as it is made was
        # given it to change.
        def game_number_given?(current, value, starting)
          return false if starting || !(value.is_a?(Value) || value.is_a?(Condition))

          current.nil? || STARTS.any? { |kind| current.is_a?(kind) }
        end

        def own_variable_while_setting_up(owner, current, value, label)
          builder = Builder.in_use
          return current unless current.nil? && (value.is_a?(Value) || value.is_a?(Condition))
          return current unless builder && !owner.is_a?(Module) && builder.instance_variable_uses.named?(owner, label)

          variable_starting_like(owner, label, value)
        end

        # The same for `@busy += 1`, which reads it as well.
        def change_target(owner, current, label, starting: false)
          current = current_or_ruby_number(current) {}
          uses = uses_while_recording(owner)
          return current unless uses
          return game_variable_of(owner, current, label) if uses.followed?(owner, label, current)

          refuse_nil_changed!(label) if current.nil?
          uses.note_change(owner, label, current, current, operator: true) unless starting
          current
        end

        # `@lives -= 1` in game code while `@lives` holds nil. Ruby would stop here with its own
        # error; in a game it is usually a routine that gives the number which the build has not
        # recorded yet, since the build records routines in its own order, not the order they run.
        def refuse_nil_changed!(label)
          raise Refused, "`#{label}` holds `nil` here, so this line cannot change it as a number. The line that " \
                         "gives `#{label}` a number can run first in the game, but VBlank does not read the lines " \
                         "in that order. To fix this, give `#{label}` a number where it is first set, like " \
                         "`#{label} = 0` in `initialize`.#{Messages::AuthorSource.at_author_line}"
        end

        # The same for a change under a test the game makes, about to be given a hidden variable
        # (Writes.promote_place), where +answer+ is Promotion.instance_variable's: a named one's game
        # variable, or what it holds, the change noted under a test the game makes.
        def promotion_target(owner, current, label, test, answer)
          case answer.reason
          when :named_instance_variable then game_variable_of(owner, current, label)
          when :not_named
            uses_while_recording(owner).note_change(owner, label, current, current, operator: false) if test.game?
            current
          else current
          end
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

        # The builder, where a test of +owner+'s +label+, holding +current+, is a test in game code of
        # a plain flag: what its sides record says whether it guards game code
        # (Steps::BuildTest#watch_flag, Uses#refuse_game_flags!). Nil for any other.
        def builder_watching_flag(owner, label, current)
          return unless Uses::FLAGS.include?(current)

          uses = uses_while_recording(owner)
          return if uses.nil? || uses.followed?(owner, label, current)

          Builder.in_use
        end

        # A read in game code of +owner+'s plain flag +label+, which held +current+.
        FlagRead = Data.define(:owner, :label, :current)

        # Where the record of plain flag reads stands now, while game code is recorded, else nil. A
        # test asks before its own test runs, then takes what was read since (#flag_reads_since):
        # the flags its answer came from, through a reader (`if door.open?`) as well.
        def flag_read_mark
          builder = Builder.in_use
          builder.instance_variable_uses.flag_read_mark if builder&.recording_game_code?
        end

        def flag_reads_since(mark) = mark ? Builder.in_use.instance_variable_uses.flag_reads_since(mark) : []

        # A test written for its value, made while building, picked a value by +read+.
        def note_flag_picks(read) = Builder.in_use.instance_variable_uses.note_flag_picks(read)

        # The side of a test of +owner+'s plain flag +label+ written at +site+ ran, and +records+
        # says whether it recorded game code.
        def note_flag_side_run(owner, label, current, site, records:)
          Builder.in_use.instance_variable_uses.note_flag_side_run(owner, label, current, site, records: records)
        end

        # ...and the side at +site+ was skipped.
        def note_flag_side_skipped(owner, label, current, site)
          Builder.in_use.instance_variable_uses.note_flag_side_skipped(owner, label, current, site)
        end

        # The game variable a named instance variable holding +current+ is: made now from a number
        # it still holds as Ruby, or the one it holds already.
        def game_variable_of(owner, current, label)
          return current if Steps.variable?(current) || current.is_a?(Condition) || current.is_a?(List)
          return list_of(owner, label, current) if list_kept?(owner, label, current)
          return make_variable(owner, label, current) if STARTS.any? { |kind| current.is_a?(kind) }
          return game_variables_in(owner, label, current) if numbers_collection?(current)

          refuse_named_object!(label, current)
        end

        # A named value is the game's from its first number. The line that first gives a named
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

          uses = builder.instance_variable_uses
          # A list is made where it is filled, which must be once, at power-on: so an Array its code
          # may change at a worked-out index is made a list at its first number, as a named one is.
          return list_of(owner, label, value) if list_kept?(owner, label, value) && uses.changing?(owner, label)
          return unless uses.named?(owner, label)
          return list_of(owner, label, value) if list_kept?(owner, label, value)
          return game_variables_in(owner, label, value) if numbers_collection?(value)
          return unless STARTS.any? { |kind| value.is_a?(kind) }

          make_variable(owner, label, value)
        end

        # Does a first number given in game code also set the variable where the line runs? Not
        # where `initialize` gives it (+starting+): that part is made once, as its routine is recorded
        # (`screen = FadedScreen.new(...)` in `scene :copyright do`), and its number is the start.
        # Anywhere else in game code the line runs on every pass, as Ruby's would.
        def first_number_set_where_reached?(starting) = Builder.in_use.recording_game_code? && !starting

        # The body of an object's `initialize` in a game file, as the rewrite runs it: a part game
        # code makes puts things into its Arrays once, as its numbers start once (Builder#making_part).
        #
        # +owner+ is the object being made, counted in the order its class's objects are made
        # (Uses#note_object_made), which names its game variables.
        #
        # A part made by code that runs every frame (a `game_loop`, a scene, a `func`) is a new
        # object on every pass in Ruby, starting again from its `initialize`, where the game would
        # keep the one the build made. That is the same only for a part whose numbers never change,
        # so one whose numbers or Arrays change is refused (Uses#changing_part?, and
        # Builder#note_made_in_part for its Arrays), unless the line keeps it as Ruby would: `@counter
        # ||= Counter.new` makes it the first time it runs (#keeping_part).
        def making_part(owner, &)
          builder = Builder.in_use
          return yield unless builder

          uses = builder.instance_variable_uses
          uses.note_object_made(owner)
          refuse_part_made_every_pass!(owner) if builder.made_every_pass? && uses.changing_part?(owner)
          builder.making_part(&)
        end

        # `@counter ||= Counter.new` (Rewriter#kept_part_text): the part made in the block, and
        # every part its `initialize` makes, is kept after its first pass (Builder#keeping_part).
        def keeping_part(&)
          builder = Builder.in_use
          builder ? builder.keeping_part(&) : yield
        end

        def refuse_part_made_every_pass!(owner)
          name = owner.class.name || "this class"
          raise Refused, "This line makes a new `#{name}` on every pass, since it is in code that runs every " \
                         "frame. Its numbers change as the game plays, and in Ruby each new one starts again " \
                         "from `initialize`. To fix this, make it above the game loop, or keep it in an instance " \
                         "variable, like `@part ||= #{name}.new(...)`, so it is made one time." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # A Hash or an Array of numbers (`@tilt_counters = { left: 0, right: 0 }`), or one already
        # made of game variables here.
        def numbers_collection?(held)
          values = held.is_a?(Hash) ? held.values : held
          return false unless (held.is_a?(Hash) || held.is_a?(Array)) && !values.empty?

          values.all? { |value| Steps.variable?(value) || STARTS.any? { |kind| value.is_a?(kind) } }
        end

        # Is +held+, given to +owner+'s named +label+, an Array of numbers kept as a list
        # (#keep_arrays_as_lists)?
        def list_kept?(owner, label, held)
          held.is_a?(Array) && !held.empty? && held.all?(Numeric) &&
            Builder.in_use.instance_variable_uses.kept_as_list?(owner, label)
        end

        # The list a named Array of numbers is, holding its items, with room for no more, and
        # named as its variable would be (`counts_by_number_part_counts`).
        def list_of(owner, label, held)
          builder = Builder.in_use
          # Each object keeps its own: a second one of the class takes the next free list name.
          held_by = Builder::ListOwner.new(owner: [:object, owner.object_id, label],
                                           at: Messages::AuthorSource.author_file_and_line)
          name = builder.plain_array_list_name(variable_name(owner, label), held_by)
          settings = held.any?(Float) ? { holds: 0.0 } : {}
          list = builder.declare_list(name, capacity: held.length, **settings)
          held.each { |item| list.push(item) }
          list
        end

        # A named hash or array of numbers is a game variable for each key, each starting from the
        # number Ruby holds there and named after the key (`tilt_counters_left`). The game reads and
        # changes one at a key known while building (`@tilt_counters[side] += 1`, with `side` a
        # symbol of a Ruby loop). A key the game works out has no slot to name, so the copy refuses
        # one (KeyedVariables); it is frozen, so a key it does not have is refused as a misspelling.
        def game_variables_in(owner, label, held)
          return held if held.is_a?(KeyedVariables)

          base = variable_name(owner, label)
          keyed = if held.is_a?(Hash)
                    KeyedHash[held.map { |key, value| [key, element_variable(owner, label, base, key, value)] }]
                  else
                    KeyedArray.new(held.each_with_index.map { |value, index| element_variable(owner, label, base, index, value) })
                  end
          keep_as_slots(keyed, owner, label).freeze
        end

        # Each variable made here is its slot's, so an instance variable handed one
        # (`@held = @states[0]`) holds it without owning it (Writes.handed_only?).
        def keep_as_slots(keyed, owner, label)
          made_here = Value::Holder.new(owner, label)
          keys = keyed.is_a?(Hash) ? keyed.keys : keyed.each_index.to_a
          keys.each { |key| keyed[key].note_holder(keyed, key) if keyed[key].holder == made_here }
          keyed
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
                                      "the numbers in an Array: the game can read an Array at an index it works out.")
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
          variable.note_ruby_start(start)
          note_made_variable(builder, variable, owner, label)
        end

        # The number Ruby held where +held+, a variable made for an instance variable, was made by a
        # build other than the one running now (or after every build has ended): a part made outside
        # the game's block, in a constant of a game file, outlives the build that made it, and the
        # next build (for another console, say) starts it again from that number. Nil for anything
        # else. Every change to such a variable was the game's, never Ruby's, so Ruby's number then
        # is Ruby's number still.
        def ruby_number_of_stale(held)
          return unless held.is_a?(Value) && !held.ruby_start.nil?

          held.ruby_start unless held.made_by?(Builder.in_use)
        end

        # +current+, or Ruby's number for a stale variable (#ruby_number_of_stale), handed to the
        # block to keep.
        def current_or_ruby_number(current)
          number = ruby_number_of_stale(current)
          return current if number.nil?

          yield number
          number
        end

        # A game variable just made for +owner+'s +label+: noted as made with no `var` line, and as
        # unsaved where the line naming it set `saved: false`. Kept as the instance variable's own.
        def note_made_variable(builder, variable, owner, label)
          builder.instance_variable_uses.note_first_number(owner, label)
          variable.note_made_with_no_var_line
          variable.note_unsaved if builder.instance_variable_uses.marked_unsaved?(owner, label)
          Writes.keep_as_own(variable, owner, label)
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

        # What game code did to the instance variables nobody named, one build's worth, kept by the
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

          # One plain flag of one object (#note_flag_change): what it held before game code first
          # changed it, the line and routine of a change that still stands, the line of a test on it
          # whose side Ruby ran and recorded game code, the sides of tests on it Ruby skipped (each
          # [site, line]), and whether a test found it nil.
          Flag = Struct.new(:started, :start, :changed_at, :changed_in, :tested_at, :skipped, :tested_nil)

          # A skipped side of a test on a flag, where it is written and the line the build was at.
          SkippedSide = Data.define(:site, :at)

          # The instance variable a variable was made for: its object and its label.
          PartVariable = Data.define(:owner, :label)

          TRACKED = [Integer, Float, Symbol].freeze # What a plain instance variable is noted holding
          FLAGS = [true, false, nil].freeze # What a plain flag holds

          def initialize
            @named_on_builder = Set.new
            @unsaved_on_builder = Set.new
            @lists_on_builder = Set.new
            @changing_on_builder = Set.new
            @changing_attributes = Set.new
            @chosen_on_builder = {}
            @names_by_class = {}
            @changing_by_class = {}
            @made_order = {}.compare_by_identity
            @made_count = Hash.new(0)
            @unsaved_by_class = {}
            @chosen_by_class = {}
            @makers_by_name = {}
            @part_variables = {}
            @first_numbers = {}
            @uses = {}.compare_by_identity
            @flags = {}.compare_by_identity
            @flag_sides = {}
            @flag_reads = []
          end

          # A side of a test on +owner+'s plain flag +label+, which held +current+, ran: written at
          # +site+, and recording game code or not (+records+). A side that records game code once
          # is taken to record it wherever it is reached.
          def note_flag_side_run(owner, label, current, site, records:)
            @flag_sides[site] = :records if records
            @flag_sides[site] ||= :quiet
            return unless records

            flag = flag_of(owner, label)
            flag.tested_at ||= Messages::AuthorSource.author_file_and_line
            flag.tested_nil ||= current.nil?
          end

          # Game code read +owner+'s plain flag +label+, holding +current+ (InstanceVariables.flag_read_mark).
          def note_flag_read(owner, label, current) = @flag_reads << FlagRead.new(owner: owner, label: label, current: current)

          def flag_read_mark = @flag_reads.length

          # The flag reads since +mark+, each flag once.
          def flag_reads_since(mark) = @flag_reads.drop(mark).uniq { |read| [read.owner.object_id, read.label] }

          # A test made while building picked a value by +read+'s flag (`@open ? 1 : 0`): it decides
          # what the game reads, as a side recording game code does.
          def note_flag_picks(read)
            flag = flag_of(read.owner, read.label)
            flag.tested_at ||= Messages::AuthorSource.author_file_and_line
            flag.tested_nil ||= read.current.nil?
          end

          # ...and one was skipped, which is judged once every routine is recorded (#refuse_game_flags!).
          def note_flag_side_skipped(owner, label, current, site)
            flag = flag_of(owner, label)
            flag.skipped[site] ||= SkippedSide.new(site: site, at: Messages::AuthorSource.author_file_and_line)
            flag.tested_nil ||= current.nil?
          end

          # A plain true or false (or NIL) in game code is decided while building wherever a test asks
          # it. That is right for a flag the build keeps for itself, and wrong for one the game keeps,
          # and two facts together tell the second: a test on it guards game code, and game code
          # leaves it changed. Asked once every routine is recorded, so the order the build met them
          # in does not matter.
          #
          # A test guards game code where a side Ruby ran recorded statements, or where Ruby skipped
          # a side that, wherever else the build ran it, recorded statements, or that the build never
          # ran at all (Steps::BuildTest#watch_flag). A side never run is unknown, so it counts, unless
          # the source shows it records nothing: refusing then costs a game one variable it names,
          # where letting it pass would freeze the flag with no word. Nothing here runs a side Ruby
          # skipped, so the answer is the same however and wherever the game is built.
          #
          # - `@seen += 1 if @open` with `@open = true` anywhere in game code: refused.
          # - `plan unless @planned` with `plan` setting `@planned = true`: the side guards building
          #   work (routines declared), not game code, as the first reach shows, and the later reaches
          #   that skip it skip that same side. Left alone. So is `return if @laid_out`.
          # - `@white = true`, then `yield`, then `@white = false` in an `ensure`: a switch set for
          #   the length of one call and put back, which is the same on every pass. Left alone.
          def refuse_game_flags!
            @flags.each do |owner, labels|
              labels.each do |label, flag|
                next unless flag.changed_at

                tested_at = flag.tested_at || flag.skipped.values.find { |side| @flag_sides[side.site] != :quiet }&.at
                refuse_game_flag!(owner, label, flag, tested_at) if tested_at
              end
            end
          end

          # A variable was just made for +owner+'s +label+, at the line running now. Recorded with
          # that line, under the class a mark would be written in (#first_number_owner).
          def note_first_number(owner, label)
            @first_numbers[[first_number_owner(owner), label]] ||= Messages::AuthorSource.author_file_and_line
          end

          # `saved: false` on +labels+, written in +marker+: the game block, or a class or module. A
          # label already given its first number has its variable made, as one a save keeps, so
          # the mark is too late. A label already marked is left alone: the line run again. A first
          # number recorded under a class counts where that class is +marker+ or is made from it.
          def refuse_late_unsaved_mark!(marker, labels)
            marking_class = marker.is_a?(Builder) ? Builder : marker
            labels.each do |label|
              next if marked_unsaved_by?(marker, label)

              made_at = @first_numbers.find { |(made_by, made_label), _| made_label == label && made_by <= marking_class }&.last
              refuse_late_mark!(label, made_at) if made_at
            end
          end

          # Clear the cache of what each class names, after a class names more.
          def clear_class_name_cache
            @names_by_class.clear
            @changing_by_class.clear
            @unsaved_by_class.clear
            @chosen_by_class.clear
          end

          def name_on_builder(labels, chosen = {}, unsaved: [])
            @named_on_builder.merge(labels)
            @unsaved_on_builder.merge(unsaved)
            @chosen_on_builder = InstanceVariables.merge_chosen_names(@chosen_on_builder, chosen)
          end

          def keep_arrays_as_lists_on_builder(labels) = @lists_on_builder.merge(labels)

          # Is an Array of numbers +owner+'s +label+ is given a list the game keeps
          # (InstanceVariables.keep_arrays_as_lists)?
          def kept_as_list?(owner, label)
            return @lists_on_builder.include?(label) if owner.is_a?(Builder)

            InstanceVariables.names_in_module(owner.class, constant: LISTS_CONSTANT).include?(label)
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

          # The variable named +name+ is made for +owner+'s +label+ (#free_name_for).
          def note_part_variable(name, owner, label) = @part_variables[name] = PartVariable.new(owner, label)

          # One game variable made for an instance variable, for `rom.profile`
          # (Diagnostics::InstanceVariableNumbers): its name, the instance variable, and whose it is.
          PartVariableNote = Data.define(:name, :label, :part)

          def part_variable_notes
            @part_variables.map do |name, made|
              part = made.owner.is_a?(Builder) ? "the game block" : made.owner.class.name || "a part"
              PartVariableNote.new(name: name, label: made.label, part: part)
            end
          end

          # A `var` or `save_var` line names +name+, which a variable of the build has already. One
          # made for an instance variable is that part's, and the line would share it with no word
          # (the other order, a part choosing a name a `var` line took, is refused at the part).
          def refuse_var_on_part_variable!(name)
            made = @part_variables[name]
            return unless made

            part = made.owner.is_a?(Builder) ? "the game block" : made.owner.class.name || "a part"
            raise Refused, "This `var` line makes the variable :#{name}. The game has a variable with that name " \
                           "already: `#{made.label}` of #{part}. One name is one variable, so this line " \
                           "changes `#{made.label}` too. To fix this, give this `var` a name of its own." \
                           "#{Messages::AuthorSource.at_author_line}"
          end

          def named?(owner, label)
            return @named_on_builder.include?(label) if owner.is_a?(Builder)

            (@names_by_class[owner.class] ||= InstanceVariables.names_in_module(owner.class)).include?(label)
          end

          def mark_changing_on_builder(labels, attributes)
            @changing_on_builder.merge(labels)
            @changing_attributes.merge(attributes)
          end

          # Can game code change +owner+'s numbers: does its class name some (`game_variables`), mark
          # some changing, or have a writer game code changes by name (#changing?)?
          def changing_part?(owner)
            holder = owner.class
            # VBlank's own objects (a pool's thing) keep the build's workings, never the game's numbers.
            return false if holder.name&.start_with?("VBlank::")
            return true unless InstanceVariables.names_in_module(holder).empty?
            return true unless InstanceVariables.names_in_module(holder, constant: CHANGING_CONSTANT).empty?

            attributes = @changing_attributes | InstanceVariables.changing_attributes_in_files
            attributes.any? { |attribute| owner.respond_to?(:"#{attribute}=") }
          end

          # +owner+'s `initialize` runs: it is the next object of its class, counted from 1.
          def note_object_made(owner) = @made_order[owner] ||= (@made_count[owner.class] += 1)

          # The variable name for +owner+'s +label+, from +name+ (InstanceVariables.free_name_for):
          # for one followed only because its code may change it, +name+ for the first object of
          # its class and `name_2` and so on for the next, in the order #note_object_made counted.
          # Any other keeps +name+, and the build takes the next free name after it.
          def made_name(owner, label, name)
            return name if owner.is_a?(Builder) || named?(owner, label) || !changing?(owner, label)

            order = @made_order[owner]
            order.nil? || order == 1 ? name : :"#{name}_#{order}"
          end

          # Is +owner+'s +label+ one its code may change as the game plays (InstanceVariables.mark_changing)?
          #
          # An attribute game code changes through a writer counts for every object whose class has
          # that writer (`dial.level += 3` marks `@level` of anything with a `level=`), since the
          # rewrite cannot tell the object's class.
          def changing?(owner, label)
            return @changing_on_builder.include?(label) if owner.is_a?(Builder)
            return true if (@changing_by_class[owner.class] ||=
                              InstanceVariables.names_in_module(owner.class, constant: CHANGING_CONSTANT)).include?(label)

            attribute = label.to_s.delete_prefix("@").to_sym
            (@changing_attributes.include?(attribute) || InstanceVariables.changing_attributes_in_files.include?(attribute)) &&
              owner.respond_to?(:"#{attribute}=")
          end

          # Is +owner+'s +label+, holding +current+, a game variable on the line of game code running
          # now? One a class names is. So is one its code may change (#changing?), from the first line
          # of game code that reads or changes it: it starts from the number Ruby holds there, which
          # setting up gave it. Not one that holds nothing yet, which has no number to start from,
          # nor one a line of game code gave a number outright before (`@named = 0`, then `@named +=
          # 1`): Ruby knows what that holds where it is read, and #note_read and #note_change keep
          # it to that.
          def followed?(owner, label, current)
            return true if named?(owner, label)
            return false unless changing?(owner, label)
            return true if Steps.variable?(current) || current.is_a?(Condition) || current.is_a?(List)
            return false if (@uses[owner] || {})[label]&.changed_at

            STARTS.any? { |kind| current.is_a?(kind) } || InstanceVariables.numbers_collection?(current)
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
          #
          # After the line, Ruby knows what it holds where the line gives it a number outright, or
          # changes the number a line of this same routine gave it outright. Not where the line runs
          # under a test the game makes (`reset if k == 2`, the write inside `reset`): only some
          # passes run it. Nor where the change works from a number another routine gave it, which
          # the game can run in either order. Then a read after it is refused (#note_read).
          def note_change(owner, label, current, value, operator:)
            return note_flag_change(owner, label, current, value) if FLAGS.include?(current) && [true, false].include?(value)
            return unless (current.nil? || plain_number?(current)) && plain_number?(value)

            use = use_of(owner, label)
            here = Messages::AuthorSource.author_file_and_line
            refuse_unnamed_change!(owner, label, here) if use.read_before_change
            builder = Builder.in_use
            routine = builder.recorded_routine_body
            given_here = use.changed_at && use.given_in.equal?(routine) && !use.changed_from_ruby_at
            unknown = builder.recording_under_game_test? || (operator && !given_here)
            use.changed_from_ruby_at = unknown ? use.changed_from_ruby_at || here : nil
            use.given_in = routine
            use.changed_at ||= here
          end

          private

          # A number or a symbol: what a game keeps and a line of game code can mean to change.
          # `true` and `false` have rules of their own (#refuse_game_flags!).
          def plain_number?(value) = TRACKED.any? { |kind| value.is_a?(kind) }

          # A line of game code gives a plain flag +value+ outright, where it held +current+. A change
          # stands until the routine that made it puts the flag back as it was before game code first
          # changed it (nil and false are one answer to a test), which is a switch held for a while
          # and the same on every pass. Put back from another routine, it is the game turning the
          # flag on and off, and the change still stands.
          def note_flag_change(owner, label, current, value)
            flag = flag_of(owner, label)
            routine = Builder.in_use.recorded_routine_body
            flag.start = current unless flag.started
            flag.started = true
            if !value == !flag.start
              flag.changed_at = flag.changed_in = nil if flag.changed_in.equal?(routine)
            elsif flag.changed_at.nil?
              flag.changed_at = Messages::AuthorSource.author_file_and_line
              flag.changed_in = routine
            end
          end

          def flag_of(owner, label) = (@flags[owner] ||= {})[label] ||= Flag.new(false, nil, nil, nil, nil, {}, false)

          def refuse_game_flag!(owner, label, flag, tested_at)
            name = label.to_s.delete_prefix("@")
            where = owner.is_a?(Builder) ? "the game block" : owner.class.name || "its class"
            start = " Then give `#{label}` `false` where it is first set." if flag.tested_nil
            raise Refused, "`#{label}` is changed while the game plays (at #{flag.changed_at}), and a test on it " \
                           "decides what the game does (at #{tested_at}). `#{label}` is a plain Ruby value, so " \
                           "the game does not see the change. Ruby decided the test once, while it built the game, " \
                           "from the value (`true` or `false`) it held then. To fix this, add `game_variables " \
                           ":#{name}` to #{where}.#{start}"
          end

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

          # +owner+ is the game block or an object: the class its first numbers are recorded under.
          def first_number_owner(owner) = owner.is_a?(Builder) ? Builder : owner.class

          # Has +marker+, the game block or a class or module, marked +label+ `saved: false` already?
          def marked_unsaved_by?(marker, label)
            return @unsaved_on_builder.include?(label) if marker.is_a?(Builder)

            InstanceVariables.names_in_module(marker, constant: UNSAVED_NAMES_CONSTANT).include?(label)
          end

          def refuse_late_mark!(label, made_at)
            raise Refused, "`game_variables` marks `#{label}` with `saved: false` here, but `#{label}` got its first " \
                           "number before this line (at #{made_at}). Its game variable is made already, and a save " \
                           "keeps it. To fix this, move the mark above the line that gives `#{label}` its first " \
                           "number.#{Messages::AuthorSource.at_author_line}"
          end

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
