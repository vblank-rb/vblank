# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # What each local name in a game block is written and read by, and where: found by reading
      # the whole block first, since `hp = 5` can only be understood from what the lines after it
      # do to `hp`. These are the facts; whether a name becomes a game variable is Promotion's to
      # decide from them (#promotion).
      class LocalNames
        include CallChanges

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
        # (see LocalNames#from_unknown_block?). +from_game_block+: made from inside a game verb's
        # block that its name's scope is outside (see LocalNames#from_game_block?).
        Write = Struct.new(:node, :in_game_code, :from_unknown_block, :from_game_block)

        CHANGES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
                   Prism::LocalVariableTargetNode, Prism::LocalVariableOrWriteNode,
                   Prism::LocalVariableAndWriteNode].freeze

        NAMES = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode].freeze

        # A `while` or an `until`, whose test and body are asked again each time round.
        LOOPS = [Prism::WhileNode, Prism::UntilNode].freeze

        # What gives a name a value outright, one name of `a, b = 1, 2` among them.
        WHOLE_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode].freeze

        # What stands for every slot of a name, and for its slots at keys worked out as the game
        # plays, among the places a change is recorded under (#names_read_by).
        SLOT_KEYS = Ractor.make_shareable({ any: :any_slot, worked_out: :slot_at_worked_out_key })

        # The verbs that run game code written somewhere else, where they are called: the routine
        # `func` made (`call`), the scene `case_var` picks, and `start_over`, which sets a part's
        # variables back to their starts.
        VERBS_RUNNING_GAME_CODE = %i[call case_var start_over].freeze

        # Writes by game code to a local of the scope the block sits in.
        attr_reader :outside_writes

        # Every method, lambda and game block: code that runs when it is called, or as the game
        # plays, after the lines around it.
        attr_reader :bodies_run_later

        # One local, in the scope that owns it: the lines that write it and read it.
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

          # `first, second = build.var(:a, 0), build.var(:b, 0)`
          attr_accessor :unpacked_from_var

          # `count, other = 0, 1`: a name whose first line is one side of that, given a number written out.
          attr_accessor :unpacked_from_value

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
        end

        # Is +node+ a call on something other than nothing or `self`?
        def self.called_on_something?(node) = !(node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

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

        # The same asked of a value alone, one right side of `count, other = 0, 1`.
        def self.value_written_out?(value)
          [Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode].include?(value.class) ||
            made_of_constants?(value)
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

        # +library_file+: the block is VBlank's own (PlainRuby.library_file?), where a method called
        # on nothing is one of VBlank's, never the game's (#game_call?).
        def initialize(block_node, library_file: false)
          @library_file = library_file
          @methods_defined = methods_defined_in(block_node)
          @locals_by_node = {}.compare_by_identity
          @outside_writes = []
          @writes_in_game_code = {}.compare_by_identity
          @reads_in_game_code = {}.compare_by_identity
          @reads_from_unknown_block = {}.compare_by_identity
          @changes_by_name = {}
          # What calls of game code change (CallChanges): the calls as read, the routines `func`
          # makes here, what each method or routine body writes, and, once resolved, the offsets
          # at which each whole name changes and those at which everything does.
          @game_calls = []
          @writes_in_methods = {}.compare_by_identity
          @in_method = false
          @sides_apart = []
          @region_start = 0
          @func_blocks = {}
          @body_changes = {}.compare_by_identity
          @body_reads = {}.compare_by_identity
          @whole_name_changes = {}
          @calls_into_game_code = []
          @names_used = Hash.new(0)
          @iterating_in_game_code = false
          @scopes_placed = {}.compare_by_identity
          @names_moved_in_game_code = {}
          @next_block_placed = false
          # The scopes a game verb's block opens (`repeat`, `game_loop`), whose lines are recorded
          # once and run as often as the game says.
          @game_block_scopes = {}.compare_by_identity
          @next_block_game = false
          # The `while` and `until` loops each write stands in, the nearest last. A block in a loop
          # runs in it; a method or a lambda runs where it is called, so it starts with none.
          @loops_around = {}.compare_by_identity
          @open_loops = []
          # The tests and loops each write sits under (Promotion#side_apart_holds?), and the
          # reads of a local handed whole to an object being made (Promotion#handed_whole_in_setup?).
          @tests_around = {}.compare_by_identity
          @open_tests = []
          @whole_arguments = {}.compare_by_identity
          @calls_on_something = []
          @unpacked_values = {}.compare_by_identity
          # Every method, lambda and game block: code that runs when it is called, or as the game
          # plays, after the lines around it (Promotion#run_later?).
          @bodies_run_later = []
          read_names(block_node, [], false)
        end

        # The one Promotion that decides, from these facts, which names become game variables.
        def promotion = @promotion ||= Promotion.new(self)

        # What a plain local given a game value keeps, for the line +write+ (Promotion#kept_copy).
        # Kept for the interpreter's test of a file of VBlank's own, which asks this.
        def copy_kept(write) = promotion.kept_copy(write).copy

        def variable_name_of(write)
          local = @locals_by_node.fetch(write)
          local.variable_name ||= next_variable_name(local.name)
        end

        # The local +node+ writes or reads, nil for any other node.
        def local_of(node) = @locals_by_node[node]

        # Is this write in game code, a Ruby loop's in game code among it?
        def written_in_game_code?(write) = @writes_in_game_code.key?(write)

        def read_in_game_code?(read) = @reads_in_game_code.key?(read)

        # Is this write in a method or a lambda, which runs where it is called?
        def written_in_method?(write) = @writes_in_methods.key?(write)

        # Is this read made from inside a block only running can place (#from_unknown_block?)?
        def read_from_unplaced_block?(read) = @reads_from_unknown_block.key?(read)

        # Is this read a whole argument of an object being made (#note_whole_arguments)?
        def whole_argument?(read) = @whole_arguments.key?(read)

        # The `while` and `until` loops +write+ stands in, the nearest last.
        def loops_around(write) = @loops_around.fetch(write, [])

        # The tests and loops +write+ sits under.
        def tests_around(write) = @tests_around.fetch(write, [])

        # Is this first write's name one that keeps what it holds (see Value#truth)?
        def keeps_truth?(write) = @locals_by_node[write]&.keeps_truth? || false

        def first_write?(write) = @locals_by_node[write]&.first_write_of?(write) || false

        # Is this a read of a method's argument (`@sound_setting = sound_setting` in `initialize`)?
        def argument_read?(read) = read.is_a?(Prism::LocalVariableReadNode) && (@locals_by_node[read]&.parameter? || false)

        # Could the name hold something as this line writes it? An argument always does.
        def holds_before_write?(write)
          local = @locals_by_node[write]
          !local.nil? && (local.parameter? || !local.first_write_of?(write))
        end

        # Is this instance variable given another name in game code, `@shown = lives`? Ruby moves the
        # name, so each number it is given is its own, and a variable it was handed is not changed.
        def moved_in_game_code?(name) = @names_moved_in_game_code.key?(name)

        # What can change what the value +write+ gives its local reads directly: a name, a place or
        # a call in that value.
        def changes_of_value(write) = named_changes(write) + changes_by_calls(write) + changes_read_through_calls(write)

        # The lines that give +local+ a value it works out (`at = get(:drum, c)`, `at += 1`). One
        # name of `a, b = get(0), get(1)` is taken to read the whole right side.
        def value_writes(local)
          local.writes.map(&:node).filter_map do |node|
            next node if node.respond_to?(:value)

            UnpackedWrite.new(value: @unpacked_values[node]) if @unpacked_values.key?(node)
          end
        end

        # One name's part of `a, b = ...`, for #value_writes.
        UnpackedWrite = Data.define(:value)

        private

        # The places +node+ reads: a local, an instance variable, or one slot or attribute of one,
        # `ball[:hp]` or `hero.x`, as written. A change to `ball[:x]` is no change to `ball[:hp]`.
        #
        # A slot's key is read too: `packed[at]` reads `at`, so `flags = packed[at]` followed by
        # `at += 1` changes what the slot's working-out would read where `flags` is used.
        #
        # Two keys written differently can be one slot: `out[i]` is changed by `out[j] = 99` when j
        # is i, which nothing here can tell. So a slot read at a key worked out as the game plays
        # is changed by a write to any slot of that name, and a slot read at a key written out
        # (`ball[:hp]`) by a write at a worked-out key (SLOT_KEYS).
        def names_read_by(node)
          return [name_key(node)] if NAMES.any? { |kind| node.is_a?(kind) }
          return [[name_key(node.receiver), node.slice], *slots_read_alike(node), *names_read_by_keys(node)] if place_read?(node)

          node.compact_child_nodes.flat_map { |child| names_read_by(child) }
        end

        def names_read_by_keys(node) = node.arguments&.arguments.to_a.flat_map { |key| names_read_by(key) }

        # The keys of SLOT_KEYS a read of +node+ is changed under, besides its own place.
        def slots_read_alike(node)
          return [] unless node.name == :[]

          kinds = keys_written_out?(node.arguments) ? %i[worked_out] : %i[worked_out any]
          kinds.map { |kind| [name_key(node.receiver), SLOT_KEYS.fetch(kind)] }
        end

        # The keys of SLOT_KEYS a write of a slot at +keys+ is recorded under, besides its own place.
        def slots_written_alike(receiver, keys)
          kinds = keys_written_out?(keys) ? %i[any] : %i[any worked_out]
          kinds.map { |kind| [receiver, SLOT_KEYS.fetch(kind)] }
        end

        # Is every key a number, a symbol or a string written out?
        def keys_written_out?(arguments)
          keys = arguments.respond_to?(:arguments) ? arguments.arguments : Array(arguments)
          keys.all? { |key| [Prism::IntegerNode, Prism::SymbolNode, Prism::StringNode].any? { |kind| key.is_a?(kind) } }
        end

        # What a name is known by here. Two methods can each have a local called `step`, and those
        # are two names. An instance variable is one name however many methods use it.
        def name_key(node) = @locals_by_node.fetch(node) { node.name }

        def place_read?(node)
          node.is_a?(Prism::CallNode) && NAMES.any? { |kind| node.receiver.is_a?(kind) } &&
            (node.name == :[] || node.arguments.nil?)
        end

        # Where +name+, a key of #names_read_by, changes: as itself, or as the whole name it is a
        # place of, by a call of game code.
        def changes_of_name(name) = @changes_by_name.fetch(name, []).map { |offset| Change.new(offset: offset, apart: []) }

        # The changes calls of game code make to what the value +write+ gives its local reads
        # (#copy_kept): the names a call this source shows can write, and, where the value reads
        # a name or calls game code, every call that can change anything. A constant or a verb's
        # answer no name of the source holds stays as it is, and so does a variable a verb hands
        # back (`frames_since_power_on`), which Steps.kept_answer never copies.
        def changes_by_calls(write)
          resolve_game_calls
          names = names_read_by(write.value)
          named = names.flat_map { |name| @whole_name_changes.fetch(whole_name(name), []) }
          return named if names.empty? && !calls_game_code?(write.value)

          named + @calls_into_game_code
        end

        # The changes to what the value +write+ gives its local reads through the calls in it
        # (CallChanges#names_read_through_calls): `at = get(:at, c)` reads `@state` inside `get`,
        # which `set(:at, c, at + 1)` writes.
        def changes_read_through_calls(write)
          names = names_read_through_calls(write.value)
          return [] if names.empty?

          resolve_game_calls
          names = (@changes_by_name.keys.map { |key| whole_name(key) } + @whole_name_changes.keys).uniq if names.include?(EVERY_NAME)
          names.flat_map { |name| changes_of_whole_name(name) + @whole_name_changes.fetch(name, []) }
        end

        # The changes the source writes to the names the value +write+ gives its local reads. A slot
        # or an attribute (`queue[0]`, `queue.length`) is changed by a change of the whole name too
        # (`queue.shift`, #record_bang_call_change).
        def named_changes(write)
          names_read_by(write.value).flat_map do |name|
            whole = name.is_a?(Array) ? changes_of_name(name.first) : []
            changes_of_name(name) + whole
          end
        end

        # Every change of +name+ or of a slot or attribute of it.
        def changes_of_whole_name(name)
          @changes_by_name.select { |key, _| whole_name(key) == name }.values.flatten.map { |offset| Change.new(offset: offset, apart: []) }
        end

        # Does +node+, or anything under it, call game code (#game_call?)?
        def calls_game_code?(node)
          (node.is_a?(Prism::CallNode) && game_call?(node)) || node.compact_child_nodes.any? { |child| calls_game_code?(child) }
        end

        # Remembers where +name+ changes, as the offset in the source.
        def record_change(name, node)
          (@changes_by_name[name] ||= []) << node.location.start_offset
        end

        # `hero.x = 1`, `ball[:hp] = 1` and their `+=`, recorded as the place a read of it writes.
        #
        # A write through a receiver worked out (`state.fetch(:at)[c] = at + 1`) names no place a
        # read could match, so it is recorded as a change of every name the receiver reads.
        def read_place_change(node)
          unless NAMES.any? { |kind| node.receiver.is_a?(kind) }
            names_read_by(node.receiver).each { |name| record_change(name, node) } if node.receiver
            return
          end

          receiver = name_key(node.receiver)
          record_change([receiver, place_written(node)], node)
          keys = slot_keys_written(node)
          slots_written_alike(receiver, keys).each { |place| record_change(place, node) } if keys
        end

        # The keys of a slot +node+ writes, or nil for an attribute it writes.
        def slot_keys_written(node)
          case node
          when Prism::IndexOperatorWriteNode then node.arguments&.arguments.to_a
          when Prism::CallNode then node.arguments.arguments[0...-1] if node.name == :[]=
          end
        end

        # `at.increase!(1)`, a verb ending in `!` called on a name, which changes the variable the
        # name holds as `at += 1` does: recorded as a change of the name. `!at` asks, and changes nothing.
        # Any other `!` verb (`list.sort!`) counts too; at worst a local keeps its line's answer.
        def record_bang_call_change(node)
          return unless CallChanges.changes_receiver?(node) && NAMES.any? { |kind| node.receiver.is_a?(kind) }

          record_change(name_key(node.receiver), node)
        end

        # Does +node+ run game code, which can change what a local was read from? A verb of
        # VERBS_RUNNING_GAME_CODE does, and so does a method of the game: it can change a name it is
        # handed (`def bump(v) = v.increase!(1)`), an instance variable, or whatever a routine it
        # calls changes. A method this source defines is the game's, whatever it is called on and
        # whatever else answers to its name. Otherwise, called on nothing, a method is the game's
        # unless VBlank or Ruby answers to it (#game_method?); called on something
        # (`reader.next_byte(0)`), what the receiver is shows only as the game runs, so it is the
        # game's unless a handle of VBlank's or a Ruby value has a method of that name
        # (CallChanges.known_method?). A verb of VBlank's own (`draw_rect_at`) and a method of a
        # value (`packed.length`) are not. What each changes is worked out in CallChanges.
        #
        # In VBlank's own files only those verbs do, called on nothing: a method there is one of
        # VBlank's, and those files are read before Builder is loaded, so it could not be told
        # from the game's. `Build.call(...)` there makes a node and runs nothing.
        def game_call?(node)
          return VERBS_RUNNING_GAME_CODE.include?(node.name) && !called_on_something?(node) if @library_file
          return true if VERBS_RUNNING_GAME_CODE.include?(node.name)
          return true if @methods_defined.key?(node.name)
          return !known_method?(node.name) if called_on_something?(node)

          game_method?(node.name)
        end

        def called_on_something?(node) = LocalNames.called_on_something?(node)

        # A method the game wrote: defined at the top of a game file (Object's), on the builder
        # alone (in its block, or by `uses`), or nowhere yet. Anything else Builder answers to is
        # VBlank's or Ruby's own.
        def game_method?(name)
          return true unless Builder.method_defined?(name) || Builder.private_method_defined?(name)

          Builder.instance_method(name).owner == Object
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

        def next_variable_name(name)
          used = @names_used[name] += 1
          used == 1 ? name : :"#{name}_#{used}"
        end

        def read_names(node, scopes, in_game_code)
          case node
          when Prism::BlockNode then read_block(node, scopes, in_game_code)
          when Prism::LambdaNode
            @bodies_run_later << node
            inside_loops([]) { inside_method { read_block(node, scopes, in_game_code) } }
          when Prism::DefNode
            @bodies_run_later << node
            inside_loops([]) { inside_method { read_block(node, [], false) } }
          when Prism::CallNode then read_call(node, scopes, in_game_code)
          when Prism::StatementsNode then read_statements(node, scopes, in_game_code)
          when Prism::WhileNode, Prism::UntilNode
            inside_loops(@open_loops + [node]) do
              inside_region(node) do
                under_test(node) do
                  with_start_after_modifier_test(node) { read_children(node, scopes, in_game_code || @iterating_in_game_code) }
                end
              end
            end
          when Prism::IfNode, Prism::UnlessNode
            under_test(node) do
              with_start_after_modifier_test(node) { read_branches(node, scopes, in_game_code || @iterating_in_game_code) }
            end
          when Prism::CaseNode, Prism::CaseMatchNode, Prism::AndNode, Prism::OrNode
            under_test(node) { read_children(node, scopes, in_game_code) }
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
               Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
               Prism::LocalVariableTargetNode then
            record_write(node, scopes, in_game_code)
            read_children(node, scopes, in_game_code)
          when Prism::MultiWriteNode
            note_unpacked_values(node, node.value)
            read_children(node, scopes, in_game_code)
            note_unpacked_variables(node)
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode
            record_change(node.name, node)
            @names_moved_in_game_code[node.name] = true if in_game_code && name_given?(node)
            read_children(node, scopes, in_game_code)
          when Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode
            read_children(node, scopes, in_game_code)
            read_place_change(node)
          when Prism::LocalVariableReadNode then
            local = scopes[-1 - node.depth]&.[](node.name)
            local&.reads&.push(node)
            @reads_in_game_code[node] = true if in_game_code
            @reads_from_unknown_block[node] = true if from_unknown_block?(node, scopes)
            @locals_by_node[node] = local if local
          else read_children(node, scopes, in_game_code)
          end
        end

        # A method or a lambda, whose lines run where it is called, which may be game code.
        def inside_method
          outer = @in_method
          @in_method = true
          yield
        ensure
          @in_method = outer
        end

        def under_test(node)
          @open_tests.push(node)
          yield
        ensure
          @open_tests.pop
        end

        def inside_loops(loops)
          outer = @open_loops
          @open_loops = loops
          yield
        ensure
          @open_loops = outer
        end

        def name_given?(write) = write.is_a?(Prism::InstanceVariableWriteNode) && NAMES.any? { |kind| write.value.is_a?(kind) }

        # Each name +targets+ unpacks (`a, (b, c) = ...`), with the whole right side it is given.
        def note_unpacked_values(targets, value)
          [*targets.lefts, targets.rest, *targets.rights].compact.each do |target|
            target = target.expression if target.is_a?(Prism::SplatNode)
            @unpacked_values[target] = value if target.is_a?(Prism::LocalVariableTargetNode)
            note_unpacked_values(target, value) if target.is_a?(Prism::MultiTargetNode)
          end
        end

        def note_unpacked_variables(node)
          return unless node.value.is_a?(Prism::ArrayNode)

          node.lefts.zip(node.value.elements).each do |target, value|
            local = @locals_by_node[target]
            next unless local && value

            local.unpacked_from_var = true if LocalNames.makes_variable?(value)
            local.unpacked_from_value = true if local.first_write_of?(target) && LocalNames.value_written_out?(value)
          end
        end

        def read_children(node, scopes, in_game_code)
          node.compact_child_nodes.each { |child| read_names(child, scopes, in_game_code) }
        end

        # An `if`'s test, then each of its sides with the other noted as a side apart
        # (@sides_apart): a call on one side never runs before a read on the other in the same
        # round (CallChanges::Change#reaches?).
        def read_branches(node, scopes, in_game_code)
          read_names(node.predicate, scopes, in_game_code)
          sides = [node.statements, node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause]
          sides.each_with_index do |side, index|
            next unless side

            other = sides[1 - index]
            apart = other ? [SideApart.new(other.location.start_offset, other.location.end_offset, node.location.start_offset, @region_start)] : []
            with_sides_apart(@sides_apart + apart) { read_names(side, scopes, in_game_code) }
          end
        end

        def with_sides_apart(sides)
          outer = @sides_apart
          @sides_apart = sides
          yield
        ensure
          @sides_apart = outer
        end

        # Code that may run again (a block, a method, a loop) starts a region of its own: a side
        # apart holds only for a local set inside the region the `if` sits in, which is set
        # again before the `if` each time round.
        def inside_region(node)
          outer = @region_start
          @region_start = node.location.start_offset
          yield
        ensure
          @region_start = outer
        end

        # Each statement read with @statement_start at its start, the offset a call in it is
        # recorded at. Under a test written after what it guards, it stays where that test ends
        # (#with_start_after_modifier_test).
        def read_statements(node, scopes, in_game_code)
          outer = @statement_start
          node.body.each do |statement|
            @statement_start = [statement.location.start_offset, outer].compact.max
            read_names(statement, scopes, in_game_code)
          end
        ensure
          @statement_start = outer
        end

        # `call :open_the_sign if near` asks `near` before the call runs, though the call is written
        # first: a call that test guards is recorded where the test ends. `begin ... end while x`
        # runs its body before the test, so it keeps the body's place.
        def with_start_after_modifier_test(node)
          outer = @statement_start
          @statement_start = node.predicate.location.end_offset if modifier_test?(node)
          yield
        ensure
          @statement_start = outer
        end

        # Where a call into game code is recorded: the start of its statement, since a working-out
        # read anywhere in that statement is read once the whole of it is recorded. That holds for
        # its own arguments too: a method reads what it is handed where it uses it, which may be
        # after the method has changed what that was worked out from.
        def call_offset(node) = @statement_start || node.location.start_offset

        def record_game_call(node)
          whole = Change.new(offset: call_offset(node), apart: @sides_apart)
          in_line = Change.new(offset: node.location.start_offset, apart: @sides_apart, statement: @statement_start || 0)
          @game_calls << GameCall.new(node, whole, in_line)
        end

        # Is +node+ a test written after the statements it guards, and asked before them?
        def modifier_test?(node)
          guarded = node.statements
          return false unless guarded && guarded.location.start_offset < node.predicate.location.start_offset

          !(LOOPS.any? { |kind| node.is_a?(kind) } && node.begin_modifier?)
        end

        def read_call(node, scopes, in_game_code)
          note_whole_arguments(node)
          @calls_on_something << node if node.receiver && node.arguments
          node.compact_child_nodes.each do |child|
            next read_ruby_iteration(child, scopes, in_game_code) if child.is_a?(Prism::BlockNode) && ruby_iteration?(node)

            # Any other block may be kept and run later: a game verb's, a pool's `each`, a part's.
            @bodies_run_later << child if child.is_a?(Prism::BlockNode)
            game_block = child.is_a?(Prism::BlockNode) && GAME_VERBS.include?(node.name)
            @next_block_placed = true if game_block
            @next_block_game = game_block
            read_names(child, scopes, in_game_code || game_block)
          end
          read_place_change(node) if node.name == :[]= || node.attribute_write?
          record_bang_call_change(node)
          note_func_block(node) if node.name == :func
          record_game_call(node) if game_call?(node)
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
          @game_block_scopes[scope] = true if @next_block_game
          @next_block_placed = false
          @next_block_game = false
          parameter_names(node.parameters).each { |name| scope[name] = Local.new(name, parameter: true) }
          # A method or a lambda runs where it is called, not on the side of an `if` it is written in.
          sides = [Prism::DefNode, Prism::LambdaNode].any? { |kind| node.is_a?(kind) } ? [] : @sides_apart
          with_sides_apart(sides) { inside_region(node) { read_children(node, scopes + [scope], in_game_code) } }
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

        # Does +node+ reach its name through a game verb's block, whose lines run as often as the
        # game says, though they are recorded once?
        def from_game_block?(node, scopes)
          node.depth.positive? && scopes.last(node.depth).any? { |scope| @game_block_scopes.key?(scope) }
        end

        def record_write(node, scopes, in_game_code)
          scope = scopes[-1 - node.depth]
          @outside_writes << node if scope.nil? && in_game_code
          return unless scope

          local = (scope[node.name] ||= Local.new(node.name, parameter: false))
          record_change(local, node)
          @writes_in_game_code[node] = true if in_game_code || @iterating_in_game_code
          @writes_in_methods[node] = true if @in_method
          local.writes << Write.new(node, in_game_code || looped_from_outside?(local), from_unknown_block?(node, scopes),
                                    from_game_block?(node, scopes))
          local.reads << node unless WHOLE_WRITES.any? { |kind| node.is_a?(kind) }
          @locals_by_node[node] = local
          @loops_around[node] = @open_loops unless @open_loops.empty?
          @tests_around[node] = @open_tests.dup unless @open_tests.empty?
        end

        # Notes each argument of +call+, an object being made (`Menus.new(...)`), that is a local
        # read whole, by position or by keyword: the object may keep it. A verb or a method takes
        # its number.
        def note_whole_arguments(call)
          return unless call.name == :new

          call.arguments&.arguments.to_a.each do |argument|
            values = argument.is_a?(Prism::KeywordHashNode) ? argument.elements.grep(Prism::AssocNode).map(&:value) : [argument]
            values.grep(Prism::LocalVariableReadNode).each { |read| @whole_arguments[read] = true }
          end
        end
      end
    end
  end
end
