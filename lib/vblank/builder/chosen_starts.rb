# frozen_string_literal: true

module VBlank
  class Builder
    # A BUILD STARTED IN A CHOSEN STATE (Cartridge::Game#starting_with): each variable and list the
    # build was given a start for starts there in place of where its `var` or `list` starts it. The
    # chosen start IS the build's start: a variable's is set where every declared start is set, as
    # the game starts; a list is made empty where it is declared and then holds the items given, in
    # order. `start_over` and a save_data record put either back there, as they put back a declared
    # start. What the game's own code does after that is the game's, as it is from any start.
    #
    # A START IS FOR WHAT THE GAME MAKES ONCE, as it starts. A variable or list a scene or routine
    # declares belongs to that routine's body, which can make it again each time it runs, so a
    # start for one is refused rather than given again on every entry.
    #
    # WHY THE PROGRAM IS BUILT WITH OTHER STARTS, rather than a state written into the running game
    # from outside (a state image on a computer's build, a probe's write on a cartridge): a program
    # is what every lowering plays, so the interpreter, the C, JavaScript and Ruby builds and every
    # console's cartridge start in the same state with nothing written for any one of them, and each
    # checked run compares its build against the interpreter started the same way. A write from
    # outside is a different thing on every runtime, and on some (a cartridge's quick memory, laid
    # out per build) has no stable place to write to. The cost is a build for each chosen state,
    # which a CartridgeCache keeps.
    module ChosenStarts
      # None of this is a verb: `var`, `list`, `start_over` and the save records ask it, and the
      # build checks what was left.
      private

      # Whether the build was given a start for +name+.
      def chosen_start?(name) = @build_options.starts.key?(name)

      # The start the build was given for the variable +name+, held to the kind its declaration
      # +declared+ is: a number for a number (true and false as 1 and 0), a fraction for a fraction
      # and a name for a variable holding names.
      def chosen_variable_start(name, declared)
        start = chosen_start_of(name)
        start = start ? 1 : 0 if [true, false].include?(start)
        kind_problem = if start.is_a?(Array)
                         "is a list of items"
                       elsif start.is_a?(Symbol) && !@name_vars.key?(name)
                         "is a name, and :#{name} holds numbers"
                       elsif !start.is_a?(Symbol) && @name_vars.key?(name)
                         "is not a name, and :#{name} holds names"
                       elsif start.is_a?(Float) != declared.is_a?(Float) && declared.is_a?(Numeric)
                         declared.is_a?(Float) ? "is a whole number, and :#{name} holds fractions" : "is a fraction, and :#{name} holds whole numbers"
                       elsif !start.is_a?(Numeric) && !start.is_a?(Symbol)
                         "is not a number"
                       end
        refuse_chosen_start!(name, start, "variable", kind_problem) if kind_problem
        # The name its declaration starts it at is one it is given, as it is in a build with no start.
        @name_vars[name].number_for(declared) if declared.is_a?(Symbol)
        start
      end

      # The power-on statement setting the variable +name+ to its chosen +start+. A name is numbered
      # once every routine is built, when every name the variable is given is known
      # (#number_chosen_name_starts!), so it waits as nought until then.
      def chosen_start_set(name, start)
        return Build.set(name, stored_node(name, start)) unless start.is_a?(Symbol)

        Build.set(name, Build.int(0)).tap { |waiting| (@chosen_name_starts ||= []) << [name, start, waiting] }
      end

      # The items the build was given for the list +name+ to start with, which holds +capacity+
      # numbers, fractions where +bits+ is set, as the power-on statements that push them.
      def chosen_list_pushes(name, capacity, bits)
        items = chosen_start_of(name)
        problem = if !items.is_a?(Array) || !items.all?(Numeric)
                    "is not a list of numbers"
                  elsif items.length > capacity
                    "has #{items.length} items, and the list holds #{capacity}"
                  elsif bits.nil? && !items.all?(Integer)
                    "has a fraction, and the list holds whole numbers"
                  end
        refuse_chosen_start!(name, items, "list", problem) if problem
        pushes = items.map { |item| Build.list_push(name, Build.int(bits ? DSL::Fraction.scale(item, bits) : item)) }
        (@chosen_list_pushes ||= {})[name] = pushes
      end

      # Whether the list +name+ was given a start.
      def chosen_list_start?(name) = @chosen_list_pushes&.key?(name) || false

      # The list +name+ made again at its chosen start: empty as +made+ (its declaration) makes it,
      # then holding the chosen items.
      def emit_chosen_list_start(name, made)
        record(Build.list_new_like(made))
        @chosen_list_pushes.fetch(name).each { |push| record(push.copy) }
      end

      def chosen_start_of(name)
        refuse_start_in_routine!(name) if @building_routine
        (@starts_used ||= Set.new) << name
        @build_options.starts.fetch(name)
      end

      def refuse_chosen_start!(name, start, what, problem)
        raise ArgumentError, "The build starts :#{name} at #{start.inspect}. :#{name} is a #{what}, and that start " \
                             "#{problem}. To fix this, give a start of the kind its declaration gives."
      end

      def refuse_start_in_routine!(name)
        routine = @building_routine.to_s
        scene = routine.start_with?("_scene_")
        where = scene ? "the scene :#{routine.delete_prefix('_scene_')}" : "the routine :#{routine}"
        raise ArgumentError, "starting_with sets :#{name}, which #{where} makes each time it #{scene ? 'starts' : 'runs'}. " \
                             "A start sets only what the game makes once, as it starts. To fix this, declare :#{name} " \
                             "outside #{where}, or play the game to that moment."
      end

      # Each chosen start that is a name, numbered as the variable numbers it: asked once every
      # routine the game wrote is built, so every name it is given is known. A name it is never
      # given is refused, since the game could never hold it: it is almost always misspelt.
      def number_chosen_name_starts!
        (@chosen_name_starts || []).each do |name, start, waiting|
          held = @name_vars.fetch(name)
          unless held.names.include?(start)
            raise ArgumentError, "The build starts :#{name} at :#{start}, and the game never gives :#{name} that " \
                                 "name. It gives #{held.names.map { |known| ":#{known}" }.join(', ')}. To fix this, " \
                                 "use one of those names."
          end
          @boot_inits[@boot_inits.index { |node| node.equal?(waiting) }] = Build.set(name, Build.int(held.number_for(start)))
        end
      end

      # Every start the build was given names a variable or list the game declared: asked once every
      # routine is built, since a scene's body declares its own.
      def refuse_starts_not_declared!
        unused = @build_options.starts.keys - (@starts_used || Set.new).to_a
        return if unused.empty?

        name = unused.first
        given = @build_options.starts.fetch(name).inspect
        if persisted?(name)
          raise ArgumentError, "The build starts :#{name} at #{given}, and :#{name} is a saved variable (`save_var`). " \
                               "It starts at what the save memory holds. To fix this, give the run save memory that " \
                               "holds it, for example `game_player(save: ...)`."
        end
        raise ArgumentError, "The build starts :#{name} at #{given}, and this build of the game declares no variable " \
                             "or list :#{name} with `var` or `list`. To fix this, use the name of one it declares, or " \
                             "build it with the feature that declares it."
      end
    end
  end
end
