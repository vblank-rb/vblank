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
          uses = owner.is_a?(Builder) ? owner.instance_variable_uses : Builder::Session.builder&.instance_variable_uses
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

        # The constant a class keeps in the instance variables it hands out through a plain reader
        # of the same name (#mark_plain_readers), as `:@counts`.
        PLAIN_READERS_CONSTANT = :VBLANK_PLAIN_READERS

        # +labels+ are instance variables +owner+, a class or module, hands out through a reader of
        # the same name that answers just what it holds (Rewriter#plain_reader_labels), which a
        # walk's read-ahead may read in the reader's place (#plain_reader?).
        def mark_plain_readers(owner, labels)
          name_in_module(owner, labels, constant: PLAIN_READERS_CONSTANT) if owner.is_a?(Module)
          nil
        end

        # Does +owner+'s `+name+` answer its instance variable of that name as it is
        # (#mark_plain_readers)? Then a rewritten line may read the instance variable in its place
        # (Rewriter#receiver_read_ahead_text), with the same answer and without calling the reader.
        def plain_reader?(owner, name)
          return false unless owner.class.public_method_defined?(name)

          defined_in = owner.class.instance_method(name).owner
          defined_in.const_defined?(PLAIN_READERS_CONSTANT, false) &&
            defined_in.const_get(PLAIN_READERS_CONSTANT, false).include?(:"@#{name}")
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
        #
        # An Array changed or read at a worked-out index through a reader is not marked here: the
        # line itself hands over the Array the reader answers (#indexed).
        def mark_changing(owner, labels, attributes: [])
          case owner
          when Builder then owner.instance_variable_uses.mark_changing_on_builder(labels, attributes)
          when Module
            name_in_module(owner, labels, constant: CHANGING_CONSTANT)
            Builder::Session.builder&.instance_variable_uses&.clear_class_name_cache
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
          builder = Builder::Session.builder
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
              mark_plain_readers(owner, [ivar.to_sym])
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
        # +set_in_routine+ is a game block's own instance variable that a `func` or a scene sets
        # (#refuse_nil_set_in_routine!).
        #
        # A plain Array of numbers handed out, while setting up too, is noted with the block that
        # gives the instance variable something else (Uses#note_array_handed): a line indexing it
        # through a reader may decide it is the game's (#indexed).
        def read_value(owner, current, label, in_text: false, set_in_routine: false, &store)
          current = current_or_ruby_number(current) { |number| yield number }
          uses = uses_while_recording(owner)
          return note_array_handed(owner, current, label, store) unless uses

          refuse_nil_set_in_routine!(label) if set_in_routine && current.nil?

          if uses.followed?(owner, label, current)
            variable = game_variable_of(owner, current, label)
            yield variable unless variable.equal?(current)
            uses.note_ruby_array_read(variable, owner, label) if variable.is_a?(KeyedArray)
            return variable
          end
          unless in_text
            note_array_handed(owner, current, label, store)
            uses.note_ruby_array_read(current, owner, label) if current.is_a?(Array)
            uses.note_read(owner, label, current)
            uses.note_flag_read(owner, label, current) if Uses::FLAGS.include?(current)
          end
          current
        end

        # A game block's instance variable +label+ is read in game code while it holds nothing, and
        # a `func` or a scene gives it a value. VBlank builds each `func` and scene after the
        # game loop, so their lines have not run yet while this one is built, though in Ruby a
        # call on an earlier pass, or earlier in this one, has set it. The line calls a method nil
        # does not answer on it (Rewriter#nil_failing_reads), so it would stop with Ruby's own
        # error. A test on such a flag has a refusal of its own (Uses#note_flag_read).
        def refuse_nil_set_in_routine!(label)
          raise Refused, "This line reads `#{label}`, which a `func` or a scene gives a value. VBlank builds " \
                         "each `func` and scene after the game loop, so `#{label}` holds nothing yet while " \
                         "VBlank builds this line. To fix this, give `#{label}` its first value above the game " \
                         "loop.#{Messages::AuthorSource.at_author_line}"
        end

        # +owner+'s +label+ hands out +current+. A plain Array of numbers is noted, by identity, in
        # the build's record (Uses#note_array_handed), with +store+, the block that gives the
        # instance variable something else. Returns +current+.
        def note_array_handed(owner, current, label, store)
          builder = Builder::Session.builder
          return current unless builder && store && !owner.is_a?(Module) && current.instance_of?(Array) &&
                                current.all?(Numeric) && !current.empty?

          builder.instance_variable_uses.note_array_handed(current, owner, label, store,
                                                           in_game_code: Builder::Session.recording?)
          current
        end

        # A line indexes +array+, the answer of a reader call (`keeper.counts` in
        # `keeper.counts[at] += 1`, LocalNames#reader_index_sites): at a key that may be worked out
        # as the game plays (+worked_out+), and writing a slot (+changed+). The answer is what the
        # line indexes.
        #
        # Only a plain Array of numbers an object's instance variable handed out just now, on a line
        # of game code, is decided here, from that object alone: an index worked out makes it a list
        # (made at power-on, holding the numbers Ruby holds now), a slot written at a known index a
        # variable per slot. The instance variable holds what it became from then on, and is
        # followed (Uses#note_changing_object). A reader of the same name in another class, or
        # another object of this one, is never touched.
        #
        # Anything else is the line's as it is: a list or slot variables decided already, a copy a
        # method made, a read while setting up, or a read at known indexes (noted as game code
        # reading Ruby's numbers, which a later change refuses).
        def indexed(array, worked_out:, changed:)
          builder = Builder::Session.builder
          return array unless builder && array.instance_of?(Array)

          uses = builder.instance_variable_uses
          hand_out = uses.take_array_hand_out(array)
          return array unless hand_out && Builder::Session.recording?
          return uses.note_array_read_in_game_code(array, hand_out) unless worked_out || changed

          uses.refuse_array_handed_before!(array, hand_out)
          owner = hand_out.owner
          label = hand_out.label
          # A part made by code that runs every frame is new on every pass in Ruby, its Array
          # starting again, where the game would keep one from power-on.
          refuse_part_made_every_pass!(owner, nil) if uses.made_every_pass?(owner)
          uses.refuse_array_kept_twice!(array, owner, label)
          uses.note_changing_object(owner, label)
          made = worked_out ? builder.recording_at_boot { list_of(owner, label, array) } : game_variables_in(owner, label, array)
          hand_out.store.call(made)
          made
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
          builder = Builder::Session.builder
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
          builder = Builder::Session.builder
          return unless Builder::Session.recording? && !owner.is_a?(Module)

          builder.instance_variable_uses
        end

        # The builder, where a test of +owner+'s +label+, holding +current+, is a test in game code of
        # a plain flag: what its sides record says whether it guards game code
        # (Steps::BuildTest#watch_flag, Uses#refuse_game_flags!). Nil for any other.
        def builder_watching_flag(owner, label, current)
          return unless Uses::FLAGS.include?(current)

          uses = uses_while_recording(owner)
          return if uses.nil? || uses.followed?(owner, label, current)

          Builder::Session.builder
        end

        # A read in game code of +owner+'s plain flag +label+, which held +current+.
        FlagRead = Data.define(:owner, :label, :current)

        # Where the record of plain flag reads stands now, while game code is recorded, else nil. A
        # test asks before its own test runs, then takes what was read since (#flag_reads_since):
        # the flags its answer came from, through a reader (`if door.open?`) as well.
        def flag_read_mark
          builder = Builder::Session.builder
          builder.instance_variable_uses.flag_read_mark if Builder::Session.recording?
        end

        def flag_reads_since(mark) = mark ? Builder::Session.builder.instance_variable_uses.flag_reads_since(mark) : []

        # A test written for its value, made while building, picked a value by +read+.
        def note_flag_picks(read) = Builder::Session.builder.instance_variable_uses.note_flag_picks(read)

        # The side of a test of +owner+'s plain flag +label+ written at +site+ ran, and +records+
        # says whether it recorded game code.
        def note_flag_side_run(owner, label, current, site, records:)
          Builder::Session.builder.instance_variable_uses.note_flag_side_run(owner, label, current, site, records: records)
        end

        # ...and the side at +site+ was skipped.
        def note_flag_side_skipped(owner, label, current, site)
          Builder::Session.builder.instance_variable_uses.note_flag_side_skipped(owner, label, current, site)
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
          builder = Builder::Session.builder
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
        def first_number_set_where_reached?(starting) = Builder::Session.recording? && !starting

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
          builder = Builder::Session.builder
          return yield unless builder

          uses = builder.instance_variable_uses
          uses.note_object_made(owner)
          if builder.made_every_pass?
            uses.note_made_every_pass(owner)
            refuse_part_made_every_pass!(owner, builder.keeper_made_every_pass) if uses.changing_part?(owner)
          end
          builder.making_part(&)
        end

        # `@counter ||= Counter.new` (Rewriter#kept_part_text): the part made in the block, and
        # every part its `initialize` makes, is kept after its first pass (Builder#keeping_part).
        #
        # +owner+ is the object whose instance variable keeps it, or nil for a local. An owner made
        # again on every pass (Uses#made_every_pass?) is new in Ruby on every pass, and so is what
        # its `||=` keeps: that part is made every pass too, and refused if it changes.
        def keeping_part(owner, &)
          builder = Builder::Session.builder
          return yield unless builder

          uses = builder.instance_variable_uses
          return uses.note_kept(builder.keeping_part(&)) unless uses.made_every_pass?(owner)

          builder.keeping_in_part_made_every_pass(owner.class.name || "this class", &)
        end

        # Runs before every `||=` that keeps a part (Rewriter#kept_part_text), even one Ruby skips
        # since +label+ holds something already: two lines in game code that keep different
        # things in one name are refused (Uses#refuse_kept_as_another!).
        def note_kept_part(owner, label, made)
          builder = Builder::Session.builder
          return unless Builder::Session.recording?

          builder.instance_variable_uses.refuse_kept_as_another!(owner, label, made)
        end

        def refuse_part_made_every_pass!(owner, keeper)
          name = owner.class.name || "this class"
          raise Refused, nested_repeated_part_message(name, keeper) if keeper

          raise Refused, "This line makes a new `#{name}` in code that runs every frame. Its numbers change " \
                         "as the game plays, and in Ruby each new one starts again from `initialize`. To fix " \
                         "this, make it above the game loop, or keep it in an instance variable, like " \
                         "`@part ||= #{name}.new(...)`, so it is made one time." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # +name+ is kept with `||=` in a +keeper+ that is itself made again on every pass.
        def nested_repeated_part_message(name, keeper)
          "This line makes a new `#{name}` and keeps it in a `#{keeper}`. But the `#{keeper}` is made in code " \
            "that runs every frame, so in Ruby a new `#{keeper}` is made on every pass, and it makes a new " \
            "`#{name}`. Each new `#{name}` starts again from `initialize`. To fix this, make the `#{keeper}` " \
            "above the game loop, or keep it in an instance variable too, like `@part ||= #{keeper}.new(...)`." \
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
            Builder::Session.builder.instance_variable_uses.kept_as_list?(owner, label)
        end

        # The list a named Array of numbers is, holding its items, with room for no more, and
        # named as its variable would be (`counts_by_number_part_counts`).
        def list_of(owner, label, held)
          builder = Builder::Session.builder
          builder.instance_variable_uses.refuse_array_kept_twice!(held, owner, label)
          # Each object keeps its own: a second one of the class takes the next free list name.
          held_by = Builder::ListOwner.new(owner: [:object, owner.object_id, label],
                                           at: Messages::AuthorSource.author_file_and_line)
          name = builder.plain_array_list_name(variable_name(owner, label), held_by)
          settings = held.any?(Float) ? { holds: 0.0 } : {}
          list = builder.declare_list(name, capacity: held.length, **settings)
          held.each { |item| list.push(item) }
          list
        end

        # +array+, the answer of a reader call that a line of game code changes as a whole with
        # +verb+ (`flock.dots << dot`, `part.counts.rotate!`; Rewriter#whole_array_change_text). A
        # part's Array becomes one the game keeps only where its own class changes it, so one
        # changed only from outside is still a Ruby Array here, or a variable for each slot: the
        # change would happen one time, while building. Refused where game code read it from an
        # instance variable; anything else (a list or a pool, an Array a method made) is the
        # line's as it is.
        def refuse_changed_from_outside!(array, verb)
          uses = Builder::Session.recording? && Builder::Session.builder.instance_variable_uses
          holder = uses && (array.instance_of?(Array) || array.is_a?(KeyedArray)) && uses.instance_variable_holding(array)
          return array unless holder

          name = holder.label.to_s.delete_prefix("@")
          raise Refused, "This line changes #{uses.kept_array_words(holder.owner, holder.label)} with `#{verb}`, " \
                         "from outside its class. VBlank makes the game keep a part's Array only where code in its " \
                         "class changes it. Here it is still a plain Ruby Array, so this line changes it one time, " \
                         "while VBlank builds the game. To fix this, change the Array in a method of its class, " \
                         "like `def add(item) = @#{name} << item`, and call that method here." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # +value+, refused where it is a named Array (KeyedArray) that a new Array would copy:
        # spread with `[*counts]` (the rewrite hands it here, Rewriter#splat_array_text) or given to
        # `Array.new(counts)` (Arrays.list_from_new and Arrays.ruby_array). Ruby copies an Array
        # without calling any of its methods there, so the KeyedArray cannot refuse it itself.
        def refuse_keyed_array_copied!(value)
          Steps.refuse_game_code!(value.copy_taken_message) if value.is_a?(KeyedArray)

          value
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

          builder = Builder::Session.builder
          suffix = key.is_a?(Symbol) || key.is_a?(Integer) || key.is_a?(String) ? key.to_s : "key"
          variable = builder.var(free_name_for(owner, label, :"#{base}_#{suffix}"), start)
          note_made_variable(builder, variable, owner, label)
        end

        # +answer+, what game code got from `h.values` or another of KeyedHash::VALUES_HANDED, refused
        # while game code is recorded where it holds a slot of a Hash of game variables: the Array
        # would change as the Hash does, where Ruby's keeps the numbers of that moment. Anything else
        # is the call's own answer.
        def refuse_hash_values_handed!(answer)
          return answer unless Builder::Session.recording?

          held = hash_slot_held(answer)
          Steps.refuse_game_code!(held.holder.object.copy_taken_message) if held
          answer
        end

        # The first variable in +answer+ (an Array or Hash, nested too) that is a slot of a KeyedHash.
        def hash_slot_held(answer)
          case answer
          when Value then answer if answer.holder&.object.is_a?(KeyedHash)
          when Array then answer.lazy.filter_map { |item| hash_slot_held(item) }.first
          when Hash then answer.each_value.lazy.filter_map { |item| hash_slot_held(item) }.first
          end
        end

        # What a named Hash or Array of numbers becomes: its slots are game variables, taken at keys
        # Ruby holds while building.
        module KeyedVariables
          def [](*keys)
            Steps.refuse_game_code!(worked_out_key_message) if keys.any?(Value)

            super
          end
        end

        class KeyedHash < Hash
          include KeyedVariables

          # The Hash verbs besides `[]=` that change a Hash in place. The game keeps a variable for
          # each key, so a verb that adds or drops a key, or gives several keys new numbers at once,
          # has nothing to change: each is refused (#whole_hash_change_message). Game code calling
          # one on a local Hash written out makes that Hash one of these (LocalNames#game_hash?),
          # so the call is refused rather than run once, while building.
          CHANGING_VERBS = %i[
            store merge! update delete delete_if keep_if select! filter! reject! compact! transform_values!
            transform_keys! clear replace shift default= default_proc= compare_by_identity rehash
          ].freeze

          # Written as source, since a method made from a block cannot be called from another Ractor.
          CHANGING_VERBS.each do |name|
            class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{name}(...)
                Steps.refuse_game_code!(whole_hash_change_message(:#{name}))
              end
            RUBY
          end

          # A copy, or a new Hash made from the slots, would hold the same game variables. A write
          # through it reaches the variable itself (Writes.change), and a read of it after the Hash
          # changes reads the new number, where Ruby's copy keeps the old one: refused even where it
          # is only read, as KeyedArray refuses its copies. Where a block worked out new numbers
          # (`transform_values { |value| value * 2 }`), the answer is Ruby's own.
          #--
          # `values`, `to_a` and the Arrays Enumerable answers stay Ruby's: the library reads a Hash
          # of game variables through them itself (#numbers_collection?, ItemQuestions).
          #++
          def dup = Steps.refuse_game_code!(copy_taken_message)
          def clone(*) = Steps.refuse_game_code!(copy_taken_message)

          HASH_ANSWERED = %i[
            to_h merge select filter reject compact slice except invert transform_values transform_keys
          ].freeze

          # Written as source, since a method made from a block cannot be called from another Ractor.
          HASH_ANSWERED.each do |name|
            class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{name}(...)
                answer = super
                Steps.refuse_game_code!(copy_taken_message) if answer.is_a?(Enumerator) || holds_own_value?(answer)
                answer
              end
            RUBY
          end

          # The calls that hand back an Array that can hold a Hash's values themselves. On a Hash of
          # game variables, game code may only read such an Array where it is made (`h.values.sum`):
          # the rewrite checks the rest as they run (Rewriter#values_handed?,
          # InstanceVariables.refuse_hash_values_handed!). The library reads one through them itself.
          VALUES_HANDED = %i[
            values to_a entries values_at fetch_values sort sort_by min_by max_by minmax_by first take drop
            take_while drop_while partition group_by zip each_slice each_cons find detect assoc rassoc map
            collect flat_map collect_concat filter_map
          ].freeze

          # Does +answer+, a new Array or Hash (nested too), hold one of this Hash's own variables?
          def holds_own_value?(answer)
            case answer
            when Array then answer.any? { |item| each_value.any? { |own| own.equal?(item) } || holds_own_value?(item) }
            when Hash then answer.each_value.any? { |value| each_value.any? { |own| own.equal?(value) } || holds_own_value?(value) }
            else false
            end
          end

          def copy_taken_message
            "This Hash holds game variables, and this line takes a copy of it, like `hash.dup` or " \
              "`hash.merge(other)`. In Ruby the copy is its own. Here the copy would hold the same variables, so " \
              "it would change when the Hash changes. To fix this, read the values one at a time, like " \
              "`left = hash[:left]`, or add them up in place, like `hash.sum { |_key, value| value }`."
          end

          def whole_hash_change_message(verb)
            "This Hash holds game variables, and this line changes it with `#{verb}`. The game keeps one " \
              "number for each key, and cannot add a key, remove a key or change many keys in one step. " \
              "To fix this, change one key at a time, like `hash[:key] = 5` or `hash[:key] += 1`."
          end

          def worked_out_key_message
            "This Hash holds game variables, and this line takes one at a key that is worked out as the game " \
              "plays. Ruby finds a slot while it builds the game, so it cannot find this one. To fix this, use a " \
              "key known while building, like a symbol from a Ruby loop (`SIDES.each do |side|`), or keep the " \
              "numbers in an Array: the game can read an Array at an index it works out."
          end
        end

        # An Array read at an index the game works out becomes a list where its own class's code
        # shows that index (`@counts[at]`), or where a line first changes it through a reader
        # (InstanceVariables.indexed). One decided before that (named with `game_variables`, or
        # first read at known indexes) is a variable for each index already.
        class KeyedArray < Array
          include KeyedVariables

          # Part of the Array (`counts[0..]`, `counts[1, 2]`) would be a new Ruby Array holding
          # the same game variables, so a change to the part would change this Array too, where
          # Ruby's part is a copy.
          def [](*keys)
            Steps.refuse_game_code!(part_taken_message) if keys.length > 1 || keys.first.is_a?(Range)

            super
          end

          def slice(*keys) = self[*keys]

          # Compared with an Array, equal only where the sizes match and every pair of items is
          # equal, as Ruby's Array#== is: a test the game makes (Steps.items_equal_test). Ruby's
          # own would ask each item `==`, which a game variable answers with a test, true to Ruby
          # whatever the numbers. `!=` is Ruby's opposite of this.
          def ==(other)
            return super unless other.is_a?(Array) || other.is_a?(List)

            Steps.items_equal_test(self, other)
          end

          # Array#eql? the same way: a whole number and a fraction are never eql?.
          def eql?(other)
            return super unless other.is_a?(Array) || other.is_a?(List)

            Steps.items_equal_test(self, other, strict: true)
          end

          # The first or last items as a new Array are a part too; the first or last item alone is
          # one of the variables, as `counts[0]` is.
          def first(*count)
            Steps.refuse_game_code!(part_taken_message) unless count.empty?

            super
          end

          def last(*count)
            Steps.refuse_game_code!(part_taken_message) unless count.empty?

            super
          end

          def take(*) = Steps.refuse_game_code!(part_taken_message)
          def drop(*) = Steps.refuse_game_code!(part_taken_message)

          # A copy, or a new Array made from the items, would hold the same game variables, as a
          # part would. A write through it reaches the variable itself (Writes.change), so the Array
          # it came from would change where Ruby's would not; refused even where it is only read.
          def dup = Steps.refuse_game_code!(copy_taken_message)
          def clone(*) = Steps.refuse_game_code!(copy_taken_message)
          def reverse = Steps.refuse_game_code!(copy_taken_message)
          def rotate(*) = Steps.refuse_game_code!(copy_taken_message)
          def values_at(*) = Steps.refuse_game_code!(copy_taken_message)
          def +(*) = Steps.refuse_game_code!(copy_taken_message)

          # Methods that hand back a new Array (or a Hash of them) that can hold the items
          # themselves. Where what comes back holds one of this Array's own variables, the answer is
          # a copy as `dup` is; where the block worked out new numbers (`map { |c| c + 1 }`), it is
          # Ruby's own. A single item (`max_by`, `min`) is one of the variables, as `counts[0]` is.
          ITEMS_ANSWERED = %i[
            map collect flat_map collect_concat select filter reject filter_map partition group_by
            sort sort_by min max min_by max_by minmax compact uniq shuffle sample zip each_slice
            each_cons take_while drop_while chunk_while slice_when entries
          ].freeze

          # Written as source, since a method made from a block cannot be called from another Ractor.
          ITEMS_ANSWERED.each do |name|
            class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{name}(...)
                answer = super
                Steps.refuse_game_code!(no_block_message) if answer.is_a?(Enumerator)
                Steps.refuse_game_code!(copy_taken_message) if !answer.equal?(self) && holds_own_item?(answer)
                answer
              end
            RUBY
          end

          # With no block these answer an Enumerator, whose later steps (`with_index`, `to_a`) can
          # hand the items on without asking this Array.
          def no_block_message
            "This Array holds game variables, and this line calls a method on it with no block, like " \
              "`counts.map.with_index`. VBlank cannot check what the next method does with the items. To " \
              "fix this, give the block to the method itself, like `counts.map { |c| c + 1 }`."
          end

          def copy_taken_message
            "This Array holds game variables, and this line takes a copy of it, like `counts.dup` or " \
              "`counts.reverse`. In Ruby the copy is its own. Here the copy would hold the same variables, " \
              "so a change to it would change the Array too. To fix this, read the items one at a time, " \
              "like `first = counts[0]`."
          end

          # Does +answer+, a new Array or Hash (nested too), hold one of this Array's own variables?
          # An item alone is not a new Array, so it is never a copy.
          def holds_own_item?(answer)
            case answer
            when Array then answer.any? { |item| any? { |own| own.equal?(item) } || holds_own_item?(item) }
            when Hash then answer.each_value.any? { |value| holds_own_item?(value) }
            else false
            end
          end

          def part_taken_message
            "This Array holds game variables, and this line takes a part of it, like `counts[0..]` or " \
              "`counts.first(2)`. In Ruby " \
              "the part is a copy, but here it would hold the same variables, so a change to it would change " \
              "the Array too. To fix this, read the items one at a time, like `counts[0]`."
          end

          def worked_out_key_message
            "This Array holds game variables, and this line takes one at an index that is worked out as the " \
              "game plays. VBlank made a variable for each index where the Array got its first numbers, so " \
              "it cannot find this one. To fix this, read the Array at the index in its class, like " \
              "`def count_at(at) = @counts[at]`, and call that method here."
          end
        end

        # `Struct.new(:count, :step)` in game code: the class it makes, its readers and writers
        # written again to come through #read_field and #write_field, which follow a field the class
        # names (`game_variables :count` in the block of `Struct.new`, or in a class made from one)
        # as a named instance variable is, and leave every other field to Ruby. A field is kept as
        # `:@count`, the label its instance variable would have, so one list of names serves. `[]`
        # and `[]=` by a field's name or place, `to_a` and `to_h` come the same way. Written as
        # source, since a method made from a block cannot be called from another Ractor.
        #
        # `Data.define(:x, :y)` makes a class whose readers note each read game code makes
        # (Uses#note_object_read), so a line giving a name a new one where game code read the old
        # one is refused (Writes.refuse_object_replaced!).
        def followed_struct(made)
          return followed_data(made) if made.is_a?(Class) && made < Data
          return made unless made.is_a?(Class) && made < Struct

          accessors = Module.new
          # Struct's own `initialize` sets the fields without their writers, so the named ones are
          # made game variables after it, as a named instance variable is at its first number.
          accessors.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def initialize(...)
              super
              ::VBlank::DSL::PlainRuby::InstanceVariables.start_fields(self)
            end

            def [](key) = ::VBlank::DSL::PlainRuby::InstanceVariables.read_field(self, ::VBlank::DSL::PlainRuby::InstanceVariables.field_at(self, key))

            def []=(key, given)
              ::VBlank::DSL::PlainRuby::InstanceVariables.write_field(self, ::VBlank::DSL::PlainRuby::InstanceVariables.field_at(self, key), given)
            end

            def to_a = members.map { |member| self[member] }
            alias deconstruct to_a
            alias values to_a
            def to_h(&) = members.to_h { |member| [member, self[member]] }.to_h(&)
            def values_at(*places) = to_a.values_at(*places)

            def each(&)
              return to_enum(:each) unless block_given?

              to_a.each(&)
              self
            end

            def each_pair
              return to_enum(:each_pair) unless block_given?

              members.each { |member| yield member, self[member] }
              self
            end

            def select(&)
              return to_enum(:select) unless block_given?

              to_a.select(&)
            end
            alias filter select

            def dig(key, *keys)
              return super unless key.is_a?(Integer) || members.include?(key.to_s.to_sym)

              found = self[key]
              keys.empty? || found.nil? ? found : found.dig(*keys)
            end

            # Ruby's own answer, from the fields as #[] reads them.
            def deconstruct_keys(keys)
              return to_h if keys.nil?
              return {} if keys.length > members.length

              keys.each_with_object({}) do |key, found|
                break found unless members.include?(key)

                found[key] = self[key]
              end
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

        # A Data class's readers, `to_h` and `deconstruct_keys` hand the copy of a game number a
        # field keeps (#copy_data_field_number!), as a Struct's do.
        def followed_data(made)
          readers = Module.new
          readers.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def initialize(...)
              super
              ::VBlank::DSL::PlainRuby::InstanceVariables.start_data_fields(self)
            end

            def to_h(&)
              copies = super().to_h do |member, held|
                [member, ::VBlank::DSL::PlainRuby::InstanceVariables.copy_data_field_number!(self, member, held)]
              end
              copies.to_h(&)
            end
            def deconstruct_keys(keys) = to_h.slice(*(keys || members))
          RUBY
          made.members.each do |field|
            readers.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{field} = ::VBlank::DSL::PlainRuby::InstanceVariables.copy_data_field_number!(self, :#{field}, super)
            RUBY
          end
          made.prepend(readers)
          made
        end

        # What +field+ of +holder+, a Struct, holds as it is, with no copy made: Ruby's own reader,
        # which a followed Struct's `[]` stands in front of (#followed_struct). Looked up on each
        # call, since a method kept in a constant cannot be shared with another Ractor.
        def field_as_held(holder, field) = Struct.instance_method(:[]).bind_call(holder, field)

        # ...and Ruby's own writer.
        def hold_in_field(holder, field, value) = Struct.instance_method(:[]=).bind_call(holder, field, value)

        # The member of +holder+, a Struct, that `[]` names by +key+: a Symbol or a String names
        # it, a whole number counts its place. Any other key is handed on as it is, for Ruby's
        # own error, except a game number, which the build cannot pick a field by.
        def field_at(holder, key)
          case key
          when Integer then holder.members[key] || key
          when String then key.to_sym
          when Value
            Steps.refuse_game_code!("This line picks a field of a `#{holder.class.name || 'Struct'}` by a number " \
                                    "the game works out. VBlank picks a field while it builds the game. To fix " \
                                    "this, name the field, like `#{holder.members.first}`.")
          else key
          end
        end

        # Game code read a field of +holder+, a Struct or a Data object (Writes.refuse_object_replaced!).
        def note_object_read(holder)
          builder = Builder::Session.builder
          builder.instance_variable_uses.note_object_read(holder) if Builder::Session.recording?
        end

        # Is +field+ of +holder+, a Struct, one its class names?
        def named_field?(holder, field)
          holder.is_a?(Struct) && names_in_module(holder.class).include?(:"@#{field}")
        end

        # Is +field+ of +holder+, a Struct, the game's: one its class names, or one game code changes
        # through its writer (`point.x += 1`, Uses#changing?) on a Struct made while setting up,
        # which lives across every pass. A Struct made by game code is most often a working-out
        # Ruby finishes as the build reaches it (a plan counted in a method `initialize` calls), so
        # its fields stay Ruby's (Uses#made_in_game_code?).
        def followed_field?(holder, field)
          return true if named_field?(holder, field)

          uses = Builder::Session.builder&.instance_variable_uses
          return false unless uses && holder.is_a?(Struct) && !uses.made_in_game_code?(holder)

          uses.changing?(holder, :"@#{field}")
        end

        # Is +field+ of +holder+ a Struct's field that stays Ruby's (#followed_field?)? A Struct with
        # no game being built is Ruby's too, as is everything a game runs outside a build.
        def ruby_field?(holder, field) = holder.is_a?(Struct) && !followed_field?(holder, field)

        def read_field(holder, field)
          refuse_field_outside_making!(holder, field)
          note_object_read(holder)
          current = copy_field_number!(holder, field)
          return current unless followed_field?(holder, field)

          read_value(holder, current, :"@#{field}") { |variable| hold_in_field(holder, field, variable) }
        end

        def write_field(holder, field, given)
          refuse_field_outside_making!(holder, field)
          unless followed_field?(holder, field)
            note_field_given(holder, field) if given.is_a?(Value)
            return hold_in_field(holder, field, given)
          end

          label = :"@#{field}"
          current = field_before_write(holder, field)
          hold_in_field(holder, field, Writes.write(current, given, [], label, moves: true, owner: holder) { |value| value })
        end

        # What +field+ of +holder+, a Struct, holds as game code reads or writes it. A Ruby Struct
        # holds a number, never a place: `AnswerPoint.new(score, 0)` or `point.x = score` keeps the
        # number `score` had on that line, and a later change to `score` leaves the field alone. So
        # a field given a game number that is not a place of its own (a name's variable, an
        # instance variable's, a working-out) is given a variable of its own here, set to that
        # number where the field was given it (#note_field_given), however much game code was
        # recorded since. A `var` handle or a sprite's `x` is a place, kept as it is, as an Array
        # keeps one (Arrays.named_place?). Where nothing was recorded since the field was given
        # it, the number is still the same, and nothing is needed: so a Struct put straight into
        # an Array costs nothing.
        #
        # It records the copy where the field was given its number and puts it in the field.
        def copy_field_number!(holder, field)
          current = field_as_held(holder, field)
          copied = recorded_field_copy(holder, field, current)
          copied.equal?(current) ? current : hold_in_field(holder, field, copied)
        end

        # The same for +field+ of +holder+, a Data object, which held +current+ as it was made. A
        # Data object cannot change, so the copy is kept beside it (Uses#data_field_copy).
        def copy_data_field_number!(holder, field, current)
          builder = Builder::Session.builder
          return current unless builder

          note_object_read(holder)
          uses = builder.instance_variable_uses
          kept = uses.data_field_copy(holder, field)
          return kept if kept

          copied = recorded_field_copy(holder, field, current)
          uses.keep_data_field_copy(holder, field, copied) unless copied.equal?(current)
          copied
        end

        # +current+, or the variable of its own that +field+ of +holder+ needs (#copy_field_number!),
        # recorded where the field was given +current+.
        def recorded_field_copy(holder, field, current)
          builder = Builder::Session.builder
          return current unless builder && copied_into_field?(holder, field, current)

          mark = builder.instance_variable_uses.field_given_at(holder, field)
          return current if mark && !builder.recorded_since?(mark)

          mark ? builder.record_at(mark) { own_field_variable(holder, field, current) } : own_field_variable(holder, field, current)
        end

        # +holder+, a Data object, is just made: each field noted as given its number here.
        def start_data_fields(holder)
          return unless Builder::Session.builder

          holder.to_h.each { |field, value| note_field_given(holder, field) if value.is_a?(Value) }
        end

        # Does +value+, given to +field+ of +holder+, stand for a number the field keeps a copy of
        # (#copy_field_number!)?
        def copied_into_field?(holder, field, value)
          return false unless value.is_a?(Value)
          return false if Writes.own_variable?(value, holder, :"@#{field}")

          !Steps.variable?(value) || value.number_in_ruby?
        end

        # A variable of +field+'s own, set to +value+ where the builder records: named as the
        # field's game variable is where game code follows the field (#followed_field?), else a
        # hidden one.
        def own_field_variable(holder, field, value)
          label = :"@#{field}"
          own = if followed_field?(holder, field)
                  variable_starting_like(holder, label, value)
                else
                  Builder::Session.builder.field_copy_variable(like: value)
                end
          Writes.store_in_variable(own, value)
          Writes.keep_as_own(own, holder, label)
        end

        # +field+ of +holder+ is given what it holds now, on the line the builder records: where a
        # copy of it is set, if game code needs one (#copy_field_number!).
        def note_field_given(holder, field)
          builder = Builder::Session.builder
          builder&.instance_variable_uses&.note_field_given(holder, field, builder.statement_mark)
        end

        # A Struct made by game code that runs again keeps Ruby's numbers, which are right only on
        # the passes that make it: a field read or written there, under the same test or in the same
        # routine, is the one Ruby has. Read anywhere else (after the `if` that made it, in another
        # routine), Ruby has the one an earlier pass made, which the game cannot follow.
        def refuse_field_outside_making!(holder, field)
          builder = Builder::Session.builder
          return unless Builder::Session.recording? && holder.is_a?(Struct)

          made_in = builder.instance_variable_uses.struct_made_in(holder)
          return if made_in.nil? || builder.recording_inside?(made_in)

          name = holder.class.name || "Struct"
          raise Refused, "This line uses `#{field}` of an object of `#{name}` that game code makes again on each " \
                         "pass. The code that makes it is in another place than this line: under an `if` that ends " \
                         "before this line, or in the game loop, another `func` or a scene. So in Ruby this line can " \
                         "use the object from an earlier pass, and VBlank cannot follow which one. To fix this, make the `#{name}` above " \
                         "the game loop, or keep it in an instance variable, like `@point ||= #{name}.new(...)`." \
                         "#{Messages::AuthorSource.at_author_line}"
        end

        # What Writes.attribute finds in a named field about to be written: as #value_before_write.
        def field_before_write(holder, field)
          value_before_write(holder, copy_field_number!(holder, field), :"@#{field}") { |variable| hold_in_field(holder, field, variable) }
        end

        # +holder+, a Struct, is just made: counted as the next of its class, which names its
        # variables in the order they were made (Uses#made_name), each field noted as given its
        # number here (#note_field_given), and each named one given its game variable
        # (#first_variable).
        def start_fields(holder)
          builder = Builder::Session.builder
          return unless builder

          uses = builder.instance_variable_uses
          uses.note_object_made(holder)
          uses.note_made_in_game_code(holder, builder.made_every_pass? ? builder.recording_container : nil) if Builder::Session.recording?
          holder.members.each do |field|
            note_field_given(holder, field) if field_as_held(holder, field).is_a?(Value)
            next unless named_field?(holder, field)

            current = field_as_held(holder, field)
            made = first_variable(holder, nil, current, :"@#{field}")
            # Made from a game variable or a working-out: a variable of its own, holding that number.
            if made.nil? && (current.is_a?(Value) || current.is_a?(Condition))
              made = variable_starting_like(holder, :"@#{field}", current)
              Writes.store_in_variable(made, current)
            end
            hold_in_field(holder, field, made) if made
          end
        end

        def make_variable(owner, label, start)
          builder = Builder::Session.builder
          variable = builder.var(free_name_for(owner, label, variable_name(owner, label)), start)
          variable.note_ruby_start(start)
          note_made_variable(builder, variable, owner, label)
        end

        # The number Ruby held where +held+, a variable made for an instance variable, was made by a
        # game whose build has ended (Value#made_in_ended_game?): a part made outside the game's
        # block, in a constant of a game file, outlives the build that made it, and the next build
        # (for another console, say) starts it again from that number. Nil for anything else. Every
        # change to such a variable was the game's, never Ruby's, so Ruby's number then is Ruby's
        # number still. A variable of a game still being built, reached from a program built as part
        # of it (a data pack's unpacking), stays a variable, and the data pack refuses the read.
        def ruby_number_of_stale(held)
          return unless held.is_a?(Value) && !held.ruby_start.nil?

          held.ruby_start if held.made_in_ended_game?
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
          chosen = Builder::Session.builder.instance_variable_uses.chosen_name(owner, label)
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
            @arrays_kept = {}.compare_by_identity
            @array_hand_outs = {}.compare_by_identity
            @arrays_read_in_game_code = {}.compare_by_identity
            @changing_objects = {}.compare_by_identity
            @chosen_on_builder = {}
            @names_by_class = {}
            @changing_by_class = {}
            @made_order = {}.compare_by_identity
            @made_count = Hash.new(0)
            @made_every_pass = {}.compare_by_identity
            @made_in_game_code = {}.compare_by_identity
            @fields_given = {}.compare_by_identity
            @objects_read = {}.compare_by_identity
            @data_field_copies = {}.compare_by_identity
            @kept_sites = {}.compare_by_identity
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
          # (InstanceVariables.keep_arrays_as_lists)? Its own class's code marks it, from the class's
          # own lines. One indexed through a reader is decided where that line runs, from the Array
          # the reader answers (InstanceVariables.indexed), never here by the reader's name.
          def kept_as_list?(owner, label)
            return @lists_on_builder.include?(label) if owner.is_a?(Builder)

            InstanceVariables.names_in_module(owner.class, constant: LISTS_CONSTANT).include?(label)
          end

          # Where one Ruby Array was made a list the game keeps (InstanceVariables.list_of): whose
          # instance variable held it, and the line.
          ArrayKept = Data.define(:owner, :label, :at)

          # +held+, a Ruby Array, is about to be made a list for +owner+'s +label+. Each list is
          # its own, so an Array that two instance variables share in Ruby (one Array handed to two
          # parts) would become two lists, and a change through one would not show through the
          # other. The second is refused.
          def refuse_array_kept_twice!(held, owner, label)
            at = Messages::AuthorSource.at_author_line
            first = @arrays_kept[held] ||= ArrayKept.new(owner: owner, label: label, at: at)
            return if first.owner.equal?(owner) && first.label == label

            words = kept_array_words(owner, label)
            raise Refused, "#{words} holds the same Array as #{kept_array_words(first.owner, first.label)}" \
                           "#{first.at}. In Ruby, the two share one Array, so a change through one shows " \
                           "through the other. The game keeps an Array for each, so they cannot share. To fix " \
                           "this, keep the Array in one part, and read it through that part in the other. Or, " \
                           "if each part must have its own numbers, give each part a copy made with `dup`.#{at}"
          end

          def kept_array_words(owner, label)
            "`#{label}` of #{owner.is_a?(Builder) ? 'the game block' : "a `#{owner.class.name || 'part'}`"}"
          end

          # One time an instance variable handed out a plain Array of numbers
          # (InstanceVariables.note_array_handed): whose, the block that gives it something else,
          # the line, and whether game code was recorded there.
          ArrayHandOut = Data.define(:owner, :label, :store, :at, :in_game_code)

          # +array+ was handed out by +owner+'s +label+. An Array another instance variable was
          # made the game's from already is refused here: the two share it in Ruby.
          def note_array_handed(array, owner, label, store, in_game_code:)
            refuse_array_kept_twice!(array, owner, label) if @arrays_kept.key?(array)
            (@array_hand_outs[array] ||= []) << ArrayHandOut.new(owner: owner, label: label, store: store,
                                                                at: Messages::AuthorSource.author_file_and_line,
                                                                in_game_code: in_game_code)
          end

          # Game code read +array+, a Ruby Array, from +owner+'s +label+ (InstanceVariables.read_value).
          def note_ruby_array_read(array, owner, label)
            @arrays_read_in_game_code[array] = PartVariable.new(owner: owner, label: label)
          end

          # The instance variable game code read +array+ from, or nil.
          def instance_variable_holding(array) = @arrays_read_in_game_code[array]

          # The hand-out of +array+ the line indexing it just made (InstanceVariables.indexed), taken
          # off the record; nil where none was noted.
          def take_array_hand_out(array) = @array_hand_outs[array]&.pop

          # Game code read +array+'s numbers as Ruby's, at known indexes, through +hand_out+: kept on
          # the record as a read a later change cannot follow. Returns +array+.
          def note_array_read_in_game_code(array, hand_out)
            (@array_hand_outs[array] ||= []) << hand_out
            array
          end

          # +array+ is about to become the game's for +hand_out+'s instance variable. Any other
          # time it was handed out it was Ruby's: game code reading Ruby's numbers, or a line
          # setting up that a local or another part may keep it from. That line cannot follow
          # this change, so it is refused, naming it. Another object handing it out shares it.
          def refuse_array_handed_before!(array, hand_out)
            earlier = @array_hand_outs.delete(array) || []
            other = earlier.find { |each| !each.owner.equal?(hand_out.owner) || each.label != hand_out.label }
            if other
              @arrays_kept[array] = ArrayKept.new(owner: other.owner, label: other.label, at: " (at #{other.at})")
              refuse_array_kept_twice!(array, hand_out.owner, hand_out.label)
            end
            return if earlier.empty?

            refuse_array_read_before_change!(hand_out, earlier.first)
          end

          def refuse_array_read_before_change!(hand_out, read)
            name = hand_out.label.to_s.delete_prefix("@")
            words = kept_array_words(hand_out.owner, hand_out.label)
            where = read.in_game_code ? "Game code reads it" : "A line reads it while the game is set up"
            raise Refused, "This line changes #{words} as the game plays, or reads it at an index the game works " \
                           "out. #{where} before this line (at #{read.at}), and there it is a plain Ruby Array: " \
                           "it keeps the numbers Ruby gave it, so it does not see this change. To fix this, " \
                           "change the Array in a method of its class, like `def bump(at) = @#{name}[at] += 1`, " \
                           "and call that method here.#{Messages::AuthorSource.at_author_line}"
          end

          # +owner+'s +label+ was made the game's where a line indexed it through a reader
          # (InstanceVariables.indexed): it is followed from then on, as one its class marks is.
          def note_changing_object(owner, label) = (@changing_objects[owner] ||= Set.new) << label

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

          # +owner+ is made by code that runs every frame and not kept (Builder#made_every_pass?),
          # so Ruby makes a new one on every pass.
          def note_made_every_pass(owner) = @made_every_pass[owner] = true

          def made_every_pass?(owner) = @made_every_pass.key?(owner)

          # +holder+, a Struct, is made while game code records (InstanceVariables.followed_field?).
          # +container+ is what it was recorded into where the line making it runs again on every
          # pass that reaches it (Builder#made_every_pass?), nil where it is made one time.
          def note_made_in_game_code(holder, container) = @made_in_game_code[holder] = container

          # Where +holder+, a Struct made by game code that runs again, was made (#note_made_in_game_code).
          def struct_made_in(holder) = @made_in_game_code[holder]

          # +made+ is what a line of game code keeps with `||=` (InstanceVariables.keeping_part): a
          # Struct kept so lives across passes, as one made while setting up does. Returns +made+.
          def note_kept(made)
            @made_in_game_code.delete(made)
            made
          end

          def made_in_game_code?(holder) = @made_in_game_code.key?(holder)

          # +field+ of +holder+, a Struct, was given what it holds at +mark+ (InstanceVariables.copy_field_number!).
          def note_field_given(holder, field, mark) = (@fields_given[holder] ||= {})[field] = mark

          def field_given_at(holder, field) = @fields_given[holder]&.[](field)

          # Game code read a field of +holder+, a Struct or a Data object.
          def note_object_read(holder) = @objects_read[holder] = true

          def object_read?(holder) = @objects_read.key?(holder)

          # The variable of its own +field+ of +holder+, a Data object, keeps (InstanceVariables.copy_data_field_number!).
          def data_field_copy(holder, field) = @data_field_copies[holder]&.[](field)

          def keep_data_field_copy(holder, field, copy) = (@data_field_copies[holder] ||= {})[field] = copy

          # One line of game code that keeps a part with `||=`: what it makes, as written, and where.
          KeptSite = Data.define(:made, :at)

          # +owner+'s +label+ (a local's name where +owner+ is nil) is kept with `||=` as +made+ on
          # the line game code is at. Ruby keeps what the line that runs first makes, which may be
          # another line than the one the build met first, so two lines that make different things
          # are refused.
          def refuse_kept_as_another!(owner, label, made)
            sites = @kept_sites[owner] ||= {}
            first = sites[label] ||= KeptSite.new(made: made, at: Messages::AuthorSource.at_author_line)
            return if first.made == made

            raise Refused, "`#{label}` keeps `#{first.made}` on one line#{first.at}, and `#{made}` on this line. " \
                           "In Ruby, `#{label}` keeps what the line that runs first makes as the game plays, and " \
                           "VBlank cannot know which line that is. To fix this, keep each one in a name of its " \
                           "own, or make `#{label}` above the game loop.#{Messages::AuthorSource.at_author_line}"
          end

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
          # rewrite cannot tell the object's class. An Array changed through a reader counts for
          # that object alone, from the line that changed it (#note_changing_object).
          def changing?(owner, label)
            return @changing_on_builder.include?(label) if owner.is_a?(Builder)
            return true if (@changing_by_class[owner.class] ||=
                              InstanceVariables.names_in_module(owner.class, constant: CHANGING_CONSTANT)).include?(label)
            return true if @changing_objects[owner]&.include?(label)

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
            if use.changed_at && !use.given_in.equal?(Builder::Session.builder.recorded_routine_body)
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
            builder = Builder::Session.builder
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
            routine = Builder::Session.builder.recorded_routine_body
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
