# frozen_string_literal: true

module VBlank
  module IR
    # A copy kept in a variable of its own, set once and read only before anything can change the
    # number it copied, is not needed: each read can work the number out again and get the same
    # answer. This finds such a copy in a finished tree and leaves it out, giving each read the
    # working-out instead. A copy is left as it is unless every condition is proven:
    #
    # - one `set` writes the copy, and nothing but plain reads names it anywhere else;
    # - the working-out reads only variables (Unchanging::READ_ONLY_VARIABLES);
    # - every read is in the lines that follow the `set` in the same block, before the first line
    #   that is not proven to leave those variables alone (Unchanging.left_alone_by?);
    # - nothing that runs outside the main flow names those variables: a timer's handler or a bend
    #   runs between any two lines of the game, and so does every routine either calls.
    module UnneededCopies
      # The statements whose bodies run outside the main flow, when the console says so.
      HANDLER_KINDS = %i[on_timer scroll_rows].freeze

      module_function

      # Every name the statements outside the main flow mention (HANDLER_KINDS, and the routines
      # they call), or nil where one of them holds raw instructions, which can change anything.
      def names_outside_main_flow(program)
        handlers = program.walk.select { |node| HANDLER_KINDS.include?(node.kind) }
        routines = Reach.routines_called_from(program, handlers)
        bodies = handlers + program.walk.select { |node| node.kind == :func && routines.include?(node.name) }
        names = Set.new
        bodies.each do |body|
          body.walk do |node|
            return nil if node.kind == :raw

            names.merge(names_in(node))
          end
        end
        names
      end

      # Leave out the copy kept in the variable +name+ of +program+, if it is not needed (see the
      # module), and answer whether it was. +outside+ is #names_outside_main_flow's answer.
      def drop!(program, name, outside)
        set, reads = writer_and_reads(program, name)
        return false if set.nil? || outside.nil?

        read = Unchanging.variables_read(set.value)
        return false if read.nil? || read.any? { |each_name| outside.include?(each_name) }

        container = program.walk.find { |node| node.children.any? { |child| child.equal?(set) } }
        slots = slots_before_change(container, set, name, read)
        return false unless slots && slots.length == reads

        slots.each { |slot| fill_slot(slot, set.value) }
        container.children.delete_if { |child| child.equal?(set) }
        true
      end

      # Leave out each copy in +names+ that one `set` gives another variable's number and nothing
      # else writes: every read of it reads that variable instead. Answers the names left out.
      #
      # Such a copy is what a place handed another's variable keeps of its own, in case game code
      # gives it a number (PlainRuby::Writes.handed_copy). Where no line does, the place only reads
      # the number, and it reads the other's variable as it stands, as one handed it always has:
      # no copy, and the same program as with none.
      def drop_unwritten!(program, names)
        wanted = names.to_set
        sets = {}
        written = Set.new
        program.walk do |node|
          next if node.kind == :var_ref

          if node.kind == :set && wanted.include?(node.var) && node.value.kind == :var_ref
            written << node.var if sets.key?(node.var)
            sets[node.var] = node
          else
            names_in(node).each { |name| written << name if wanted.include?(name) }
          end
        end
        dropped = sets.reject { |name, _| written.include?(name) }
        return [] if dropped.empty?

        replace_reads(program, dropped)
        remove_sets(program, dropped.values)
        dropped.keys
      end

      # Each read of a name in +sets+ becomes a read of what its `set` gave it.
      def replace_reads(program, sets)
        program.walk do |node|
          node.attrs.each do |field, held|
            if held.is_a?(Array)
              next unless held.any? { |each_held| dropped_read?(each_held, sets) }

              node.set_operand(field, held.map { |each_held| dropped_read?(each_held, sets) ? sets[each_held.name].value.copy : each_held })
            elsif dropped_read?(held, sets)
              node.set_operand(field, sets[held.name].value.copy)
            end
          end
        end
      end

      def dropped_read?(held, sets) = held.is_a?(Node) && held.kind == :var_ref && sets.key?(held.name)

      def remove_sets(program, sets)
        removed = ->(child) { sets.any? { |set| set.equal?(child) } }
        containers = program.walk.select { |node| node.children.any?(&removed) }
        containers.each { |node| node.children.delete_if(&removed) }
      end

      # The one `set` of +name+ and how many times +name+ is read, or nil where anything else names it.
      def writer_and_reads(program, name)
        sets = []
        reads = 0
        program.walk do |node|
          if node.kind == :var_ref && node.name == name then reads += 1
          elsif node.kind == :set && node.var == name then sets << node
          elsif names_in(node).include?(name) then return nil
          end
        end
        sets.one? ? [sets.first, reads] : nil
      end

      # Where +name+ is read in the lines after +set+ in +container+, each a Slot, or nil where it is
      # read after a line that may change a variable in +read+. A line that changes one and reads
      # +name+ too works the number out first only where it holds no lines of its own.
      def slots_before_change(container, set, name, read)
        after = container.children.drop_while { |child| !child.equal?(set) }.drop(1)
        slots = []
        open = true
        after.each do |statement|
          found = slots_holding(statement, name)
          return nil if !found.empty? && !open

          slots.concat(found)
          next if Unchanging.left_alone_by?(statement, read)
          return nil if !found.empty? && !statement.leaf?

          open = false
        end
        slots
      end

      # One operand that holds a read of the copy: +node+'s operand +field+, at +index+ where the
      # operand is an Array of nodes.
      Slot = Data.define(:node, :field, :index)

      def slots_holding(statement, name)
        statement.walk.flat_map do |node|
          node.attrs.flat_map do |field, held|
            if held.is_a?(Array)
              held.each_index.filter_map { |at| Slot.new(node, field, at) if read_of?(held[at], name) }
            elsif read_of?(held, name)
              [Slot.new(node, field, nil)]
            else []
            end
          end
        end
      end

      def read_of?(held, name) = held.is_a?(Node) && held.kind == :var_ref && held.name == name

      # Put a fresh copy of +working_out+ where +slot+ read the copy.
      def fill_slot(slot, working_out)
        if slot.index.nil?
          slot.node.set_operand(slot.field, working_out.copy)
        else
          held = slot.node.operand_named(slot.field).dup
          held[slot.index] = working_out.copy
          slot.node.set_operand(slot.field, held)
        end
      end

      # Every name +node+'s operands hold, a variable's among them.
      def names_in(node) = node.attrs.values.flatten.grep(Symbol)
    end
  end
end
