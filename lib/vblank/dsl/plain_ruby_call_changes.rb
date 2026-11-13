# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # WHAT A CALL OF GAME CODE CAN CHANGE, for LocalNames#read_after_it_changes?, as a second file
      # of LocalNames: it reads the names LocalNames found. A local set from a game value is a
      # working-out, read where it is used, so a call between its line and that use that changes
      # what it was read from makes it read the new value. Copying every such local costs a
      # variable each, which a game of any size cannot afford, so a call counts only as a change of
      # what the code it runs can write, where this source shows that code:
      #
      # - a method this source defines (`def next_byte`), on whatever it is called: the instance
      #   variables it writes, and what it is handed when it writes through an argument
      #   (`place.increase!(1)`), followed into the methods and routines it calls;
      # - `call :step_on`, of a routine this source makes with `func(:step_on) { ... }`: the names
      #   its block writes;
      # - a method of the game's own object from another file (`reader.next_byte(0)`): that object
      #   and what it is handed.
      #
      # Code this source does not show (a method of another file called on nothing, `call` of a
      # routine made elsewhere, `case_var`, `start_over`) can change anything, so it counts as a
      # change of every name.
      module CallChanges
        # What one call can change: +names+, each as #names_read_by keys it (a local, an instance
        # variable), or +everything+.
        Changes = Data.define(:names, :everything) do
          def self.of_names(names) = new(names: names.uniq, everything: false)

          def self.union_of(list)
            return EVERYTHING if list.any?(&:everything)

            of_names(list.flat_map(&:names))
          end
        end

        EVERYTHING = Ractor.make_shareable(Changes.new(names: [], everything: true))
        NOTHING = Ractor.make_shareable(Changes.new(names: [], everything: false))

        # Stands, among the names a method changes, for the arguments its caller hands it.
        CALLER_ARGUMENTS = Ractor.make_shareable(Object.new)

        # The other side of an `if` a change sits on, from +from+ to +to+ in the source, and where
        # the region the `if` sits in starts (LocalNames#inside_region).
        SideApart = Data.define(:from, :to, :region_start)

        # Where a name changes: from +offset+ in the source on, but not on the +apart+ sides of the
        # `if`s it sits in. With +statement+, the change is a call later in a statement than a
        # write inside it (`(f = t[at]) + bump(at) + f`), and reaches only a local that statement sets.
        Change = Data.define(:offset, :apart, :statement) do
          def initialize(offset:, apart:, statement: nil) = super

          # Does this change come after the line +write+, so it can matter to the local it sets?
          def after?(write) = offset > write.location.end_offset && (statement.nil? || write.location.start_offset >= statement)

          # Does it come before +read+ of the local +write+ sets? A side apart counts only for a
          # local set inside the region of its `if`, set again before the `if` each time round.
          def reaches?(read, write)
            at = read.location.start_offset
            at >= offset && apart.none? { |side| at.between?(side.from, side.to) && write.location.start_offset > side.region_start }
          end
        end

        # A call that may run game code, and its two Changes: +whole_statement+, from where its
        # statement is read as a whole (LocalNames#call_offset), and +in_statement+, from the call
        # itself, for a local set earlier in that same statement.
        GameCall = Data.define(:node, :whole_statement, :in_statement) do
          def changes = [whole_statement, in_statement]
        end

        # The Ruby values a game's names hold besides VBlank's handles, whose methods are Ruby's.
        VALUE_CLASSES = [Integer, Float, String, Symbol, Array, Hash, Range, NilClass, TrueClass, FalseClass,
                         Struct, Data, Comparable, Enumerable, Kernel].freeze

        # The name of every method a module of VBlank's or a VALUE_CLASSES defines. Worked out
        # once in each Ractor, when a game is first read, since every handle is loaded by then.
        def self.known_method_names
          Ractor.current[:vblank_known_method_names] ||= begin
            names = VALUE_CLASSES.flat_map(&:instance_methods)
            names.concat(vblank_modules.flat_map { |mod| mod.instance_methods(false) + mod.private_instance_methods(false) })
            names.to_set
          end
        end

        # VBlank and every module and class under it.
        def self.vblank_modules(mod = VBlank, found = {}.compare_by_identity)
          return found.keys if found.key?(mod)

          found[mod] = true
          mod.constants(false).each do |name|
            next if mod.autoload?(name)

            inner = constant_in(mod, name)
            vblank_modules(inner, found) if inner.is_a?(Module) && inner.name&.start_with?("VBlank::")
          end
          found.keys
        end

        # A constant another Ractor may not read (a table not made shareable) is no module.
        def self.constant_in(mod, name)
          mod.const_get(name, false)
        rescue Ractor::IsolationError
          nil
        end

        # The routine a `func` or a `call` names written out (`:step_on`), or nil.
        def self.routine_named(node)
          name = node.arguments&.arguments&.first
          name.unescaped.to_sym if name.is_a?(Prism::SymbolNode)
        end

        # `x.increase!(1)`: a verb ending in `!` on something, which changes it. `!x` asks.
        def self.bang_call?(node) = node.name != :! && node.name.end_with?("!") && !node.receiver.nil?

        private

        # Does a handle of VBlank's or a Ruby value have a method called +name+? Called on
        # something, such a method is taken to be that, and not the game's.
        def known_method?(name) = CallChanges.known_method_names.include?(name)

        # Each routine `func` makes in this source, by name, and the blocks that make it.
        def note_func_block(node)
          name = CallChanges.routine_named(node)
          (@func_blocks[name] ||= []) << node.block if name && node.block.is_a?(Prism::BlockNode)
        end

        # Every method +node+ defines, however deep, by name.
        def methods_defined_in(node, found = {})
          (found[node.name] ||= []) << node if node.is_a?(Prism::DefNode)
          node.compact_child_nodes.each { |child| methods_defined_in(child, found) }
          found
        end

        # Each game call read, recorded as a change of what it can change: of the names it
        # can write, or, where it can change anything, in @calls_into_game_code. Once, after the
        # whole source is read, since a method may be defined below the line that calls it.
        def resolve_game_calls
          return if @game_calls_resolved

          @game_calls_resolved = true
          @game_calls.each do |call|
            changes = changes_of_call(call.node)
            next @calls_into_game_code.concat(call.changes) if changes.everything

            changes.names.each { |name| (@whole_name_changes[name] ||= []).concat(call.changes) }
          end
        end

        # What a call LocalNames#game_call? counts can change.
        def changes_of_call(node)
          return changes_of_func_call(node) if node.name == :call
          return EVERYTHING if LocalNames::VERBS_RUNNING_GAME_CODE.include?(node.name)
          object = called_on_something?(node)
          # Called on something, a name this source defines may also be another class's method of
          # another file, so the object and what it is handed count too.
          return Changes.union_of([changes_of_defined_method(node), (changes_of_object_call(node) if object)].compact) if @methods_defined.key?(node.name)
          return changes_of_object_call(node) if object

          EVERYTHING
        end

        # A method this source defines: what its definitions write, with what its caller hands it
        # where it writes through an argument.
        def changes_of_defined_method(node)
          method = Changes.union_of(@methods_defined.fetch(node.name).map { |definition| changes_inside_body(definition) })
          return method unless method.names.include?(CALLER_ARGUMENTS)

          Changes.of_names(method.names - [CALLER_ARGUMENTS] + names_handed(node))
        end

        # A method of an object of the game's, defined in another file (`reader.next_byte(0)`): it
        # can write the object it is called on and what it is handed, and only those.
        def changes_of_object_call(node) = Changes.of_names(names_read_by(node.receiver).map { |key| whole_name(key) } + names_handed(node))

        def changes_of_func_call(node)
          blocks = @func_blocks[CallChanges.routine_named(node)]
          return EVERYTHING unless blocks

          Changes.union_of(blocks.map { |block| changes_inside_body(block) })
        end

        # The names the arguments of +node+ read, each a whole name: a method writing through
        # what it is handed may write any slot of it.
        def names_handed(node) = node.arguments&.arguments.to_a.flat_map { |argument| names_read_by(argument) }.map { |key| whole_name(key) }

        def whole_name(key) = key.is_a?(Array) ? key.first : key

        # What a method's or a routine's +body+ can write. A body that calls back into itself
        # adds nothing the first time round has not.
        def changes_inside_body(body)
          return @body_changes[body] if @body_changes.key?(body)

          @body_changes[body] = NOTHING
          @body_changes[body] = Changes.union_of(changes_written_under(body, body, body.is_a?(Prism::DefNode)))
        end

        # What +node+ and everything under it write, leaving out a method defined inside +body+.
        def changes_written_under(node, body, in_method)
          return [] if node.is_a?(Prism::DefNode) && !node.equal?(body)

          own = change_written_at(node, in_method)
          node.compact_child_nodes.flat_map { |child| changes_written_under(child, body, in_method) } + [own]
        end

        # What +node+ itself writes, inside a method (+in_method+) or a routine's block.
        def change_written_at(node, in_method)
          case node
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
               Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
            Changes.of_names([node.name])
          when *LocalNames::CHANGES
            # A method's own locals end with it; a routine's block writes the names around it.
            in_method ? NOTHING : Changes.of_names([@locals_by_node.fetch(node) { node.name }])
          when Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode then change_through(node.receiver, in_method)
          when Prism::CallNode then change_by_inner_call(node, in_method)
          else NOTHING
          end
        end

        def change_by_inner_call(node, in_method)
          writes = node.name == :[]= || node.attribute_write? || CallChanges.bang_call?(node)
          through = writes ? change_through(node.receiver, in_method) : NOTHING
          return through unless game_call?(node)

          Changes.union_of([through, as_method_changes(changes_of_call(node), in_method)])
        end

        # A write through +receiver+ (`place.increase!(1)`, `@state.fetch(:at)[c] = 1`) changes
        # the name it starts from: an instance variable, a name a routine's block sees, or, from a
        # method's argument, whatever its caller hands it. A method's own local may hold anything
        # (`list = @kept`), and so may the answer of a call, so a write through either can change
        # anything.
        def change_through(receiver, in_method)
          root = receiver
          root = root.receiver while root.is_a?(Prism::CallNode) && root.receiver
          return EVERYTHING unless LocalNames::NAMES.any? { |kind| root.is_a?(kind) }

          key = name_key(root)
          return Changes.of_names([key]) unless in_method && key.is_a?(LocalNames::Local)

          key.parameter? ? Changes.of_names([CALLER_ARGUMENTS]) : EVERYTHING
        end

        # What a call inside a method changes, as changes of that method: a name it was handed
        # stands for CALLER_ARGUMENTS, and a local of its own may hold anything.
        def as_method_changes(changes, in_method)
          return changes if changes.everything || !in_method

          locals, others = changes.names.partition { |name| name.is_a?(LocalNames::Local) }
          return EVERYTHING unless locals.all?(&:parameter?)

          Changes.of_names(others + (locals.empty? ? [] : [CALLER_ARGUMENTS]))
        end
      end
    end
  end
end
