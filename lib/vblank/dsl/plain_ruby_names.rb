# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # What each local name in a game block is: found by reading the whole block first, since
      # `hp = 5` can only be understood from what the lines after it do to `hp`.
      #
      # A name is a GAME VARIABLE if it is given a number and also changed in game code, or was
      # made directly by `var`. Everything else is left as Ruby: a number nothing changes
      # stays a plain number and costs nothing, and `target = hero_x` is a second name.
      class LocalNames
        # The verbs whose blocks hold code the game runs as it plays. A plain Ruby block, like
        # the one given to `8.times`, runs while building however it is nested. `fill_from_copy` is
        # a data pack's unpacking routine (`slots.fill_from_copy`), game code of a program of its own.
        GAME_VERBS = %i[game_loop scene func each_pass every after repeat once_a_frame on_tick item
                        fill_from_copy].freeze

        ARITHMETIC = %i[+ - * / % << >> -@ abs].freeze

        # How Ruby goes over a list or a count. Called on something written out in the source, a
        # constant or a literal or a range, it runs here and now however deep in game code it
        # sits: `MELODY.each { cursor += dur }` in a game loop is adding up while building. On
        # a name it cannot be told from a pool's `each`, so that counts as game code.
        RUBY_ITERATORS = %i[downto each each_index each_slice each_with_index each_with_object flat_map map select
                            step times upto].freeze

        # +from_unknown_block+: made from inside a block on something only running can tell apart
        # (see LocalNames#from_unknown_block?).
        Write = Struct.new(:node, :in_game_code, :from_unknown_block)

        CHANGES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
                   Prism::LocalVariableTargetNode, Prism::LocalVariableOrWriteNode,
                   Prism::LocalVariableAndWriteNode].freeze

        NAMES = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode].freeze

        # A `while` or an `until`, whose test and body are asked again each time round.
        LOOPS = [Prism::WhileNode, Prism::UntilNode].freeze

        # What gives a name a value outright, one name of `a, b = 1, 2` among them.
        WHOLE_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode].freeze

        # Writes by game code to a local of the scope the block sits in.
        attr_reader :outside_writes

        # One local, in the scope that owns it.
        class Local
          attr_reader :name, :writes, :reads
          attr_accessor :variable_name

          def initialize(name, parameter:)
            @name = name
            @parameter = parameter
            @writes = []
            @reads = []
          end

          def read_from?(offset) = reads.any? { |read| read.location.start_offset >= offset }

          def parameter? = @parameter
          def first_write = @writes.first
          def first_write_of?(node) = first_write.node.equal?(node)

          # On any line: `glint = nil` can be filled in later by code that runs later.
          def made_by_var? = unpacked_from_var || @writes.any? { |write| LocalNames.var_call?(write.node) }

          # `first, second = build.var(:a, 0), build.var(:b, 0)`
          attr_accessor :unpacked_from_var

          def auto_variable?
            return false if parameter? || !starts_variable?

            @writes.drop(1).any?(&:in_game_code)
          end

          # A number changed from a block that may be a pool's `each`, which only running it can
          # tell from a Ruby list's: see Rewriter#guarded_write_text. A name only read here (one of a
          # block around, or Ruby's own) has no write to decide by.
          def changed_from_unknown_block?
            !@writes.empty? && !variable? && starts_as_number? && @writes.drop(1).any?(&:from_unknown_block)
          end

          # A number or a yes or no written out. A name started as nil is often filled in later
          # with something no game can keep, a point of a place or a sprite.
          def starts_as_number? = %i[other yes_or_no].include?(LocalNames.kind_written(first_write.node))

          # In setting up, whatever a name is given is looked at as the line runs, so any start
          # will do. In game code a worked-out start stays a working-out, which Ruby's arithmetic
          # carries down the lines and which costs no memory.
          def starts_variable?
            return true if LocalNames.starts_from_value?(first_write.node)

            WHOLE_WRITES.any? { |kind| first_write.node.is_a?(kind) } && !first_write.in_game_code
          end

          def plain_name? = parameter? || !variable?

          # Does this name hold nil, or both a number and true or false? One kept number cannot
          # show which of those it is.
          def keeps_truth?
            kinds = @writes.map { |write| LocalNames.kind_written(write.node) }
            return false if holds_only_yes_or_no?(kinds)

            kinds.include?(:nil) || (kinds.include?(:yes_or_no) && kinds.include?(:other))
          end

          # nil and false read the same in a test, so a name nobody asks `.nil?` is a yes or no.
          def holds_only_yes_or_no?(kinds)
            !asked_nil && kinds.all? { |kind| %i[nil yes_or_no].include?(kind) }
          end

          attr_accessor :asked_nil

          def variable? = auto_variable? || made_by_var?
        end

        def self.var_call?(write)
          return false unless write.respond_to?(:value)

          makes_variable?(write.value)
        end

        # `var :x, 0`, on anything: a part of a game is handed the builder and calls `build.var`.
        # ...and a ternary whose two sides each do, of which a plain test runs one.
        def self.makes_variable?(value)
          return value.is_a?(Prism::CallNode) && %i[var save_var].include?(value.name) unless ternary?(value)

          [value.statements, value.subsequent.statements].all? { |side| side.body.one? && makes_variable?(side.body.first) }
        end

        def self.ternary?(value) = value.is_a?(Prism::IfNode) && value.if_keyword_loc.nil?

        # `x == nil` or `x != nil`, `nil` on either side and written out, with one other side.
        def self.nil_comparison?(call)
          return false unless %i[== !=].include?(call.name) && call.receiver && call.arguments&.arguments&.one?

          [call.receiver, call.arguments.arguments.first].one?(Prism::NilNode)
        end

        # What a #nil_comparison? asks about: the side that is not `nil`.
        def self.side_not_nil(call)
          call.receiver.is_a?(Prism::NilNode) ? call.arguments.arguments.first : call.receiver
        end

        def self.number?(write)
          write.is_a?(Prism::LocalVariableWriteNode) &&
            [Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode,
             Prism::NilNode].include?(write.value.class)
        end

        # What a write shows it gives a name. Only a value written out can show it, so a name given
        # another name is left to what it starts as.
        def self.kind_written(write)
          return unless write.is_a?(Prism::LocalVariableWriteNode)

          case write.value
          when Prism::NilNode then :nil
          when Prism::TrueNode, Prism::FalseNode then :yes_or_no
          when Prism::IntegerNode, Prism::FloatNode then :other
          end
        end

        # A number written out, or something only running the line can show is one: `state = PLAYING`,
        # `x = WIDTH / 2`. See Rewriter#declaration.
        def self.starts_from_value?(write)
          number?(write) || (write.is_a?(Prism::LocalVariableWriteNode) && made_of_constants?(write.value))
        end

        def self.made_of_constants?(node)
          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::IntegerNode, Prism::FloatNode then true
          when Prism::ParenthesesNode then made_of_constants?(node.body.body.first)
          when Prism::CallNode
            ARITHMETIC.include?(node.name) && made_of_constants?(node.receiver) &&
              node.arguments&.arguments.to_a.all? { |each_argument| made_of_constants?(each_argument) }
          else false
          end
        end

        def initialize(block_node)
          @locals_by_node = {}.compare_by_identity
          @outside_writes = []
          @promoted_writes = {}.compare_by_identity
          @first_writes_in_game_code = {}.compare_by_identity
          @reads_in_game_code = {}.compare_by_identity
          @reads_from_unknown_block = {}.compare_by_identity
          @changes_by_name = {}
          @names_used = Hash.new(0)
          @iterating_in_game_code = false
          @scopes_placed = {}.compare_by_identity
          @names_moved_in_game_code = {}
          @next_block_placed = false
          read_names(block_node, [], false)
        end

        # What a rewritten `x = ...` does: nil to leave it, :declare for the line that makes a
        # variable while setting up, :start for one that makes it in game code and so sets it
        # every pass, :assign to change the variable. A method's argument is its own value, as in
        # Ruby, so a write to one changes nothing the caller holds.
        def action_for(write)
          local = @locals_by_node[write]
          return if local.nil? || local.parameter?
          return first_write_action(local) if local.first_write_of?(write)
          return unless local.variable?

          LocalNames.var_call?(write) ? nil : :assign
        end

        # Does this write only change what a name holds, as any Ruby name does?
        def plain_name_write?(write) = @locals_by_node[write]&.plain_name? || false

        def variable_name_of(write)
          local = @locals_by_node.fetch(write)
          local.variable_name ||= next_variable_name(local.name)
        end

        # The plain names +sides+ change that are read after +node+, in a conditional or a loop that
        # may turn out to be a test the game makes. A name read nowhere else needs nothing. It
        # stops at a block, whose writes are not in the same scope as the test.
        #
        # A loop's test and body are asked again on the next round, so a name a loop changes is
        # read after the change when it is read in the loop before that change: by the test
        # (`more = copy.word(at)` read by `while more != 0`), by a line above it, or by the change
        # itself (`at += 16`). Left plain, the game's loop would ask about the number it held when
        # the loop was recorded, and never end. A name written and then read further down the same
        # round only carries a working-out down the lines, as in any game code, and stays plain.
        def names_to_promote(node, sides)
          writes = sides.compact.flat_map { |side| plain_writes_in(side) }
          kept = writes.select do |write|
            local = @locals_by_node[write]
            local.read_from?(node.location.end_offset) || (loop?(node) && read_next_round?(local, node, write))
          end
          kept.each { |write| @promoted_writes[write] = true }
          kept.map(&:name).uniq
        end

        # A name given a working-out holds no number: the game works it out at each read, so it
        # follows whatever it was made from, where a Ruby name keeps the answer from its line.
        # That matters only if something it reads changes and the name is read after. In game
        # code the line runs again each pass, so the read has to follow the change. In setting up
        # it runs once, and game code reading the name comes round again after any change.
        def read_after_it_changes?(write)
          local = @locals_by_node[write]
          return false unless local&.plain_name? && write.is_a?(Prism::LocalVariableWriteNode)

          from = write.location.end_offset
          changes = names_read_by(write.value).flat_map { |name| @changes_by_name.fetch(name, []) }
                                              .select { |offset, _in_game| offset > from }
          return false if changes.empty?
          return true if local.read_from?(changes.map(&:first).min)

          !@first_writes_in_game_code[write] && local.reads.any? { |read| @reads_in_game_code[read] }
        end

        def loop?(node) = LOOPS.any? { |kind| node.is_a?(kind) }

        # Is +local+ read in +loop+ at or before +write+, so the next round reads what it wrote?
        def read_next_round?(local, loop, write)
          from = loop.location.start_offset
          to = write.location.start_offset
          local.reads.any? { |read| read.location.start_offset.between?(from, to) }
        end

        # The instance variables, slots and attributes +sides+ change, each written on a plain name.
        def places_changed_in(sides) = sides.compact.flat_map { |side| places_in(side) }

        # Does a test the game makes around +sides+ have anything to do first?
        def changes_under?(node, sides) = !names_to_promote(node, sides).empty? || !places_changed_in(sides).empty?

        # A key Ruby can read a second time with nothing changing.
        def self.plain_key?(key)
          [Prism::SymbolNode, Prism::IntegerNode, Prism::StringNode, Prism::LocalVariableReadNode].any? { |kind| key.is_a?(kind) }
        end

        # Does each of +sides+ write +name+, so that it holds something whichever way the test goes?
        def written_on_every_side?(name, sides)
          sides.none?(&:nil?) && sides.length > 1 &&
            sides.all? { |side| plain_writes_in(side).any? { |write| write.name == name } }
        end

        # Is this first write's name one that keeps what it holds (see Value#truth)?
        def keeps_truth?(write) = @locals_by_node[write]&.keeps_truth? || false

        # Is this a write to a name that #names_to_promote named?
        def promoted?(write) = @promoted_writes.key?(write)

        def first_write?(write) = @locals_by_node[write]&.first_write_of?(write) || false

        # Could the name hold something as this line writes it? An argument always does.
        def holds_before_write?(write)
          local = @locals_by_node[write]
          !local.nil? && (local.parameter? || !local.first_write_of?(write))
        end

        # Is this instance variable given another name in game code, `@shown = lives`? Ruby moves the
        # name, so each number it is given is its own, and a variable it was handed is not changed.
        def moved_in_game_code?(name) = @names_moved_in_game_code.key?(name)

        # Is this write's name a number changed from a block only running can place?
        def changed_from_unknown_block?(write) = @locals_by_node[write]&.changed_from_unknown_block? || false

        # Is this a read of such a name, from inside a block only running can place? Read there
        # before the block's own write, the name must already be the game variable it will be.
        def read_from_unknown_block?(read)
          @reads_from_unknown_block.key?(read) && (@locals_by_node[read]&.changed_from_unknown_block? || false)
        end

        # Is this write's name a game variable?
        def variable_write?(write) = @locals_by_node[write]&.variable? || false

        # Is this read of a local a read of a game variable?
        def variable_read?(read) = @locals_by_node[read]&.variable? || false

        private

        # The places +node+ reads: a local, an instance variable, or one slot or attribute of one,
        # `ball[:hp]` or `hero.x`, as written. A change to `ball[:x]` is no change to `ball[:hp]`.
        def names_read_by(node)
          return [name_key(node)] if NAMES.any? { |kind| node.is_a?(kind) }
          return [[name_key(node.receiver), node.slice]] if place_read?(node)

          node.compact_child_nodes.flat_map { |child| names_read_by(child) }
        end

        # What a name is known by here. Two methods can each have a local called `step`, and those
        # are two names. An instance variable is one name however many methods use it.
        def name_key(node) = @locals_by_node.fetch(node) { node.name }

        def place_read?(node)
          node.is_a?(Prism::CallNode) && NAMES.any? { |kind| node.receiver.is_a?(kind) } &&
            (node.name == :[] || node.arguments.nil?)
        end

        # Remembers where +name+ changes.
        def record_change(name, node, in_game_code)
          (@changes_by_name[name] ||= []) << [node.location.start_offset, in_game_code]
        end

        # `hero.x = 1`, `ball[:hp] = 1` and their `+=`, recorded as the place a read of it writes.
        def read_place_change(node, in_game_code)
          return unless NAMES.any? { |kind| node.receiver.is_a?(kind) }

          record_change([name_key(node.receiver), place_written(node)], node, in_game_code)
        end

        def place_written(node)
          receiver = node.receiver.slice
          case node
          when Prism::IndexOperatorWriteNode then "#{receiver}[#{node.arguments&.slice}]"
          when Prism::CallOperatorWriteNode then "#{receiver}.#{node.read_name}"
          else
            return "#{receiver}.#{node.name.to_s.delete_suffix('=')}" unless node.name == :[]=

            "#{receiver}[#{node.arguments.arguments[0...-1].map(&:slice).join(', ')}]"
          end
        end

        def places_in(node)
          return [] if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          own = changed_place?(node) ? [node] : []
          own + node.compact_child_nodes.flat_map { |child| places_in(child) }
        end

        def changed_place?(node)
          case node
          when Prism::InstanceVariableWriteNode then !LocalNames.makes_variable?(node.value)
          when Prism::InstanceVariableOperatorWriteNode then true
          when Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode then plain_receiver?(node.receiver)
          when Prism::CallNode then (node.name == :[]= || node.attribute_write?) && plain_receiver?(node.receiver)
          else false
          end
        end

        def plain_receiver?(receiver) = (NAMES + [Prism::SelfNode]).any? { |kind| receiver.is_a?(kind) }

        # A block inside a side runs while building, on that side, so a name of the scope around it
        # that it changes is changed on that side: +blocks+ counts the blocks gone into, and a write
        # whose depth reaches past them is one. A method or a lambda runs when it is called, which
        # may be anywhere, so its writes are not: a lambda's change to a name around it comes from a
        # block only running can place, and is decided as it runs (#from_unknown_block?).
        def plain_writes_in(node, blocks = 0)
          return plain_writes_in_children(node, blocks + 1) if node.is_a?(Prism::BlockNode)
          return [] if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          own = plain_name_write?(node) && CHANGES.any? { |kind| node.is_a?(kind) } && node.depth >= blocks ? [node] : []
          own + plain_writes_in_children(node, blocks)
        end

        def plain_writes_in_children(node, blocks) = node.compact_child_nodes.flat_map { |child| plain_writes_in(child, blocks) }

        def first_write_action(local)
          return if local.made_by_var? || !local.auto_variable?

          local.first_write.in_game_code ? :start : :declare
        end

        def next_variable_name(name)
          used = @names_used[name] += 1
          used == 1 ? name : :"#{name}_#{used}"
        end

        def read_names(node, scopes, in_game_code)
          case node
          when Prism::BlockNode, Prism::LambdaNode then read_block(node, scopes, in_game_code)
          when Prism::DefNode then read_block(node, [], false)
          when Prism::CallNode then read_call(node, scopes, in_game_code)
          when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode
            read_children(node, scopes, in_game_code || @iterating_in_game_code)
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
               Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
               Prism::LocalVariableTargetNode then
            record_write(node, scopes, in_game_code)
            read_children(node, scopes, in_game_code)
          when Prism::MultiWriteNode
            read_children(node, scopes, in_game_code)
            note_unpacked_variables(node)
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode
            record_change(node.name, node, in_game_code)
            @names_moved_in_game_code[node.name] = true if in_game_code && name_given?(node)
            read_children(node, scopes, in_game_code)
          when Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode
            read_children(node, scopes, in_game_code)
            read_place_change(node, in_game_code)
          when Prism::LocalVariableReadNode then
            local = scopes[-1 - node.depth]&.[](node.name)
            local&.reads&.push(node)
            @reads_in_game_code[node] = true if in_game_code
            @reads_from_unknown_block[node] = true if from_unknown_block?(node, scopes)
            @locals_by_node[node] = local if local
          else read_children(node, scopes, in_game_code)
          end
        end

        def name_given?(write) = write.is_a?(Prism::InstanceVariableWriteNode) && NAMES.any? { |kind| write.value.is_a?(kind) }

        def note_unpacked_variables(node)
          return unless node.value.is_a?(Prism::ArrayNode)

          node.lefts.zip(node.value.elements).each do |target, value|
            local = @locals_by_node[target]
            local.unpacked_from_var = true if local && value && LocalNames.makes_variable?(value)
          end
        end

        def read_children(node, scopes, in_game_code)
          node.compact_child_nodes.each { |child| read_names(child, scopes, in_game_code) }
        end

        def read_call(node, scopes, in_game_code)
          node.compact_child_nodes.each do |child|
            next read_ruby_iteration(child, scopes, in_game_code) if child.is_a?(Prism::BlockNode) && ruby_iteration?(node)

            game_block = child.is_a?(Prism::BlockNode) && GAME_VERBS.include?(node.name)
            @next_block_placed = true if game_block
            read_names(child, scopes, in_game_code || game_block)
          end
          read_place_change(node, in_game_code) if node.name == :[]= || node.attribute_write?
          @locals_by_node[node.receiver]&.asked_nil = true if node.name == :nil?
          @locals_by_node[LocalNames.side_not_nil(node)]&.asked_nil = true if LocalNames.nil_comparison?(node)
        end

        def ruby_iteration?(call) = RUBY_ITERATORS.include?(call.name) && written_out?(call.receiver)

        # Is this a constant, a number, a list or a range in the source, or a call on one?
        def written_out?(node)
          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::ArrayNode, Prism::RangeNode,
               Prism::IntegerNode then true
          when Prism::ParenthesesNode then written_out?(node.body.body.first)
          when Prism::CallNode then !node.receiver.nil? && written_out?(node.receiver)
          else false
          end
        end

        # A test inside it can still be one the game makes, so what is under a conditional there
        # stays game code. See the IfNode line in #read_names.
        def read_ruby_iteration(block, scopes, in_game_code)
          outer = @iterating_in_game_code
          @iterating_in_game_code = outer || in_game_code
          @next_block_placed = true
          read_names(block, scopes, false)
        ensure
          @iterating_in_game_code = outer
        end

        # A block of Ruby's own iteration runs while building, as the line does, and a game verb's
        # records game code. Any other block may be either (a pool's `each`, or a Ruby list's), and
        # only running it can tell. Each scope a block opens is noted with which it is.
        def read_block(node, scopes, in_game_code)
          scope = {}
          @scopes_placed[scope] = true if @next_block_placed
          @next_block_placed = false
          parameter_names(node.parameters).each { |name| scope[name] = Local.new(name, parameter: true) }
          read_children(node, scopes + [scope], in_game_code)
        end

        def parameter_names(node)
          return [] unless node

          own = node.respond_to?(:name) && node.name ? [node.name] : []
          own + node.compact_child_nodes.flat_map { |child| parameter_names(child) }
        end

        # A Ruby loop in game code runs while building, and its body is recorded each time round.
        # A name it adds up from a start of its own in the same pass stays a Ruby number. A name
        # started outside game code carries over from pass to pass, so only the game can keep it.
        def looped_from_outside?(local)
          @iterating_in_game_code && !local.first_write.nil? && !local.first_write.in_game_code
        end

        # Does +node+ reach its name through a block that may be game code? The scopes between the
        # write and its name's are the last +depth+ of them.
        def from_unknown_block?(node, scopes)
          node.depth.positive? && scopes.last(node.depth).any? { |scope| !@scopes_placed.key?(scope) }
        end

        def record_write(node, scopes, in_game_code)
          scope = scopes[-1 - node.depth]
          @outside_writes << node if scope.nil? && in_game_code
          return unless scope

          local = (scope[node.name] ||= Local.new(node.name, parameter: false))
          record_change(local, node, in_game_code)
          @first_writes_in_game_code[node] = true if in_game_code
          local.writes << Write.new(node, in_game_code || looped_from_outside?(local), from_unknown_block?(node, scopes))
          local.reads << node unless WHOLE_WRITES.any? { |kind| node.is_a?(kind) }
          @locals_by_node[node] = local
        end
      end
    end
  end
end
