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

        # `game_variables :busy, :seed`, written in a class's body, a module's, or the game block
        # (+owner+ is whichever ran it). The rewrite turns the call into this one.
        def name_game_variables(owner, names)
          labels = names.map { |name| instance_variable_label(name) }
          case owner
          when Builder then owner.instance_variable_uses.name_on_builder(labels)
          when Module then name_in_module(owner, labels)
          else refuse_named_outside_class!(owner)
          end
          nil
        end

        # `:busy` as `:@busy`.
        def instance_variable_label(name)
          unless name.is_a?(Symbol) || name.is_a?(String)
            raise Refused, "`game_variables` takes the names of instance variables, like `game_variables :busy`. " \
                           "It was given #{name.inspect}.#{Messages::AuthorSource.at_author_line}"
          end

          :"@#{name.to_s.delete_prefix('@')}"
        end

        # A class keeps its names in a constant, which every Ractor that builds a game can read. The
        # same line run again (a file loaded twice) changes nothing.
        def name_in_module(owner, labels)
          labels = labels.uniq
          if owner.const_defined?(NAMES_CONSTANT, false)
            return if owner.const_get(NAMES_CONSTANT, false) == labels

            raise Refused, "#{owner.name || 'This class'} names its game variables in two lines. To fix this, name " \
                           "all of them in one `game_variables` line.#{Messages::AuthorSource.at_author_line}"
          end

          owner.const_set(NAMES_CONSTANT, Ractor.make_shareable(labels))
        end

        def refuse_named_outside_class!(owner)
          raise Refused, "`game_variables` names the instance variables of a class, so it goes in the class's body. " \
                         "Here it is called on #{Writes.object_words(owner)}. To fix this, move it to the line after " \
                         "`class`.#{Messages::AuthorSource.at_author_line}"
        end

        # The instance variables +holder+ and the classes and modules it is made from name.
        def names_in_module(holder)
          holder.ancestors.flat_map do |each_module|
            each_module.const_defined?(NAMES_CONSTANT, false) ? each_module.const_get(NAMES_CONSTANT, false) : []
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
        def write_target(owner, current, value, label, starting: false)
          uses = uses_while_recording(owner)
          return current unless uses

          unless uses.named?(owner, label)
            uses.note_change(owner, label, current, value, operator: false) unless starting
            return current
          end
          return game_variable_of(owner, current, label) unless current.nil?
          return current unless Writes.number_kept?(value) && !value.nil?

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

          refuse_named_object!(label, current)
        end

        def make_variable(owner, label, start)
          builder = Builder.in_use
          variable = builder.var(builder.free_variable_name(variable_name(owner, label)), start)
          variable.note_made_with_no_var_line
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
        # block's `@score`. An object of a class with no name is a `part`'s.
        def variable_name(owner, label)
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
            @names_by_class = {}
            @uses = {}.compare_by_identity
          end

          def name_on_builder(labels) = @named_on_builder.merge(labels)

          def named?(owner, label)
            return @named_on_builder.include?(label) if owner.is_a?(Builder)

            (@names_by_class[owner.class] ||= InstanceVariables.names_in_module(owner.class)).include?(label)
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
