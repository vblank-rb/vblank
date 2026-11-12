# frozen_string_literal: true

require "prism"

module VBlank
  module DSL
    # A game block written in normal Ruby.
    #
    # A block runs once, while the game is built, to record what the game will do. Ruby lets
    # nobody change what `if`, `&&` or `x = 1` mean, so underneath they are calls that record
    # a branch, a join and a change. This reads the block's own source with Prism and writes those few
    # constructs out as calls, and runs that instead. Everything else in the block, the verbs
    # above all, is left as it was written.
    #
    # NOTHING HERE GUESSES A TYPE. Whether `if hp > 0` is a test for the game or for the build
    # cannot be read off the source, so each construct becomes a small step (PlainRuby::Steps)
    # that looks at the value as the block runs: `if console == :gbc` stays plain Ruby.
    #
    # A BRANCH'S CODE STAYS WHERE IT WAS WRITTEN, inside parentheses in a real Ruby `if`, and is
    # never moved into a block. So the locals it sets outlive it and every line keeps its
    # number, which is what makes an error name the author's own line.
    module PlainRuby
      # Something a game block cannot do, said in plain words before the game is built.
      class Refused < BuildError; end

      # What opens a scope of its own, whose jumps and locals stay in it.
      OWN_SCOPES = [Prism::BlockNode, Prism::LambdaNode, Prism::DefNode].freeze

      # What a `case ... in` pattern can hold and still be asked as a `when` is.
      WHEN_VALUES = [Prism::IntegerNode, Prism::FloatNode, Prism::RangeNode, Prism::SymbolNode, Prism::StringNode,
                     Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::NilNode, Prism::TrueNode,
                     Prism::FalseNode].freeze

      # The verbs that use what their block's last line gives back as a number the game works out.
      ANSWERING_BLOCK_VERBS = %i[scroll_each_row].freeze

      module_function

      # +block+ again, as a proc that runs the rewritten source. It closes over what +block+
      # closed over, so the game's own constants and locals still resolve. +allow+ names
      # libraries the block may use, on the author's word that they are safe here.
      #
      # THIS RUNS AS THE GAME IS DECLARED, because the block's binding is only there to read until
      # a game is made shareable between Ractors (Cartridge::Game#shareable_if_possible). The proc
      # this makes is cut loose in its place, so everything it needs later is written into it.
      #
      # +checked+ false leaves the checks out, for a block that has good reason to reach further
      # than a game does: a test's, which names its own helpers.
      def rewrite(block, allow: [], checked: true)
        file, line = block.source_location
        rewriter = Rewriter.new(*source_and_block_of(block), outer_locals: block.binding.local_variables,
                                                             source_label: "#{file}:#{line}")
        code = callable_source(rewriter, block)
        source = checked ? checked_source(rewriter, code, file, allow) : code
        eval(source, block.binding, file, line) # rubocop:disable Security/Eval
      end

      # What a game runs for +block+: the block rewritten, or as it is if it cannot be, as with one
      # made from a method, or one this module made already.
      def game_block(block, allow: [])
        refuse_block_with_no_file!(block)
        rewritable?(block) ? rewrite(block, allow: allow, checked: game_blocks_checked?) : block
      end

      def game_blocks_checked? = true

      # A game read from standard input, given with `ruby -e` or made by `eval` has no file to read
      # back, so none of it could be read as normal Ruby. Run as it stands, `x += 1` would do nothing.
      def refuse_block_with_no_file!(block)
        path = block.source_location&.first
        return unless ["-", "-e"].include?(path) || path&.start_with?("(eval")

        raise Refused, "This game has no file, so VBlank cannot read it. To fix this, save it in a " \
                       "`.rb` file and run that file."
      end

      # A lambda stays one, since it checks what it is given and a proc does not. `->` has its
      # arrow in its own text, and `lambda { }` does not.
      def callable_source(rewriter, block)
        return rewriter.rewritten_block if rewriter.block_node.is_a?(Prism::LambdaNode)

        "#{block.lambda? ? 'lambda' : 'proc'} #{rewriter.rewritten_block}"
      end

      def checked_source(rewriter, code, file, allow)
        checks = BlockChecks.new(rewriter.block_node, file: file, allow: allow)
        checks.refuse_outside_calls!
        checks.refuse_changed_outside_locals!(rewriter.outside_writes)
        checks.refuse_game_code_in_plain_files!
        "proc { |*__plain_ruby_given| #{checks.constant_check}; (#{code}).call(*__plain_ruby_given) }"
      end

      # Can +block+ be rewritten? It takes a file to read and a scope to run in, and a proc this
      # module made already has no file of its own, which is how it is not rewritten twice.
      def rewritable?(block)
        iseq = RubyVM::InstructionSequence.of(block)
        return false unless iseq&.absolute_path && File.file?(iseq.absolute_path)

        block.binding
        true
      rescue ArgumentError
        false
      end

      # What the block's source is rewritten into, for reading and for a test.
      def rewritten_source(block) = Rewriter.new(*source_and_block_of(block)).rewritten_block

      # The block's file and its node. A file is read and parsed once, per Ractor since a tree is
      # not shared.
      def source_and_block_of(block)
        path, line = block.source_location
        source, blocks = parsed_file(path)
        starting = blocks.fetch(line, [])
        found = starting.one? ? starting.first : node_at_column(starting, block)
        unless found.is_a?(Prism::BlockNode) || found.is_a?(Prism::LambdaNode)
          raise Refused, "No block starts at line #{line}, so this game cannot be read."
        end

        [source, found]
      end

      # The last that starts by that column, since Ruby counts a `->` from its body, not its arrow.
      def node_at_column(nodes, block)
        column = block_start_column(block)
        nodes.select { |node| node.location.start_column <= column }.max_by { |node| node.location.start_column }
      end

      # Which column +block+ starts at, which only matters when two start on one line. Ruby can
      # answer, but asking from several Ractors at once crashes or hangs it, since they share the
      # block's code. A held file lock is the only lock Ractors can share.
      def block_start_column(block)
        File.open(__FILE__) do |file|
          file.flock(File::LOCK_EX)
          RubyVM::InstructionSequence.of(block).to_a[4][:code_location][1]
        end
      end

      def parsed_file(path)
        files = (Ractor.current[:plain_ruby_parsed_files] ||= {})
        files[path] ||= begin
          source = File.binread(path)
          [source, code_by_line(Prism.parse(source).value, Hash.new { |all, line| all[line] = [] })]
        end
      end

      # Methods are listed too, since a proc made from one is not a block to rewrite, and must not
      # be taken for a block beside it on the line.
      def code_by_line(node, found)
        case node
        when *OWN_SCOPES then found[node.location.start_line] << node
        end
        node.compact_child_nodes.each { |child| code_by_line(child, found) }
        found
      end

      # A whole file of a game in normal Ruby, the file a game splits a part into, as source,
      # checked as a game block is: an outside call stops it here, and an outside constant as the
      # file finishes running (BlockChecks#file_constant_check says why there). +loaded_from+ is the
      # folder of the file that brought it in, whose constants are the game's too. A file of
      # VBlank's own library brought in this way (DSL::Pool, Original::CopyReader) builds games and
      # is never one, so it is not checked.
      def rewritten_file(path, loaded_from: File.dirname(path))
        source = File.binread(path)
        root = Prism.parse(source).value
        # What stands before the first line of code stays: the magic comment that freezes the
        # file's strings is there, and so is every line the numbers after it count from.
        opening = source.byteslice(0, root.location.start_offset).force_encoding(Encoding::UTF_8)
        rewritten = "#{opening}#{Rewriter.new(source, source_label: File.expand_path(path)).rewritten(root)}"
        return rewritten if File.expand_path(path).start_with?(BlockChecks.library_folder)

        checks = BlockChecks.new(root, file: path, allow: [])
        checks.refuse_outside_calls_in_file!
        "#{rewritten}\n#{checks.file_constant_check(loaded_from: loaded_from)}\n"
      end

      # The block's source with its constructs written out as calls. It builds new text rather
      # than editing in place, since a trailing `if` is evaluated before what stands to its left.
      class Rewriter
        STEPS = "::VBlank::DSL::PlainRuby::Steps"
        WRITES = "::VBlank::DSL::PlainRuby::Writes"
        NEW_VALUE = "__plain_ruby_new"
        JUMPS = [Prism::ReturnNode, Prism::BreakNode, Prism::NextNode].freeze

        attr_reader :block_node

        # +outer_locals+ are the names the block's scope holds. Written further down the method a
        # block sits in, one is no local to the block as Ruby first read it, and yet it is to
        # `eval`: `screen :tiled` would stop being a call. Those calls are written with `self.`.
        #
        # +source_label+ names the block or file, so a local of its own keeps a variable of its own
        # beside a local of the same name in another (Builder#plain_local_variable). Nil for a
        # rewrite only read, never run.
        def initialize(source, block_node = nil, outer_locals: [], source_label: nil)
          @source = source
          @block_node = block_node
          @outer_locals = outer_locals
          @source_label = source_label
          @answers = 0
          @open_tests = []
          @lone_joins = {}.compare_by_identity
          @tail_ternaries = {}.compare_by_identity
          @block_tests = []
          # The patterns of a `case ... in` left to Ruby, which are Ruby's own syntax and not
          # expressions to rewrite, and the subjects such a `case` asks about.
          @written_as_is = {}.compare_by_identity
          @pattern_subjects = {}.compare_by_identity
          @heredoc_parts = []
          # Each run of statements being rewritten, the outermost first, with how many tests were
          # open as it began. A block, a lambda or a method starts with none.
          @open_statements = []
        end

        def rewritten_block = rewritten(@block_node)

        def outside_writes = @names.outside_writes

        def rewritten(node)
          @names = LocalNames.new(node)
          @heredoc_parts = heredoc_parts_in(node).sort_by { |part| part.location.start_offset }
          rewritten_text(node)
        end

        private

        # The source from +from+ to +upto+. A heredoc's lines sit past the end of the node that
        # opened it, so they are copied by whatever text follows that node, and only here can each
        # `#{...}` among them be rewritten as the one-line String's is (#embedded_text). Each part
        # of the source is copied once, so each is rewritten once, in its place.
        def between(from, upto)
          parts = @heredoc_parts.select { |part| part.location.start_offset >= from && part.location.end_offset <= upto }
          return source_between(from, upto) if parts.empty?

          at = from
          text = parts.map do |part|
            piece = source_between(at, part.location.start_offset) + embedded_text(part)
            at = part.location.end_offset
            piece
          end
          text.join + source_between(at, upto)
        end

        def source_between(from, upto) = @source.byteslice(from...upto).force_encoding(Encoding::UTF_8)

        # Each `#{...}` in a heredoc's lines under +node+.
        def heredoc_parts_in(node)
          own = heredoc?(node) ? node.parts.grep(Prism::EmbeddedStatementsNode) : []
          own + node.compact_child_nodes.flat_map { |child| heredoc_parts_in(child) }
        end

        def heredoc?(node)
          [Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode].any? { |kind| node.is_a?(kind) } &&
            node.opening_loc&.slice&.start_with?("<<")
        end

        # Only the line ends between two places, so what follows keeps its line number.
        def line_ends_between(from, upto) = "\n" * source_between(from, upto).count("\n")

        def rewritten_text(node)
          return source_between(node.location.start_offset, node.location.end_offset) if @written_as_is.key?(node)
          return "#{STEPS}.plain_pattern_subject(#{argument(node)})" if @pattern_subjects.delete(node)

          case node
          when Prism::IfNode, Prism::UnlessNode then conditional_text(node)
          when Prism::CaseNode then case_text(node)
          when Prism::CaseMatchNode then case_match_text(node)
          when Prism::EmbeddedStatementsNode then embedded_text(node)
          when Prism::ForNode then for_text(node)
          when Prism::WhileNode then loop_text(node, "loop_while")
          when Prism::UntilNode then loop_text(node, "loop_until")
          when Prism::AndNode then joined_text(node, "join_both")
          when Prism::OrNode then joined_text(node, "join_either")
          when Prism::CallNode then call_text(node)
          when Prism::LocalVariableWriteNode then guarded_write_text(node, write_text(node))
          when Prism::LocalVariableOperatorWriteNode then guarded_write_text(node, change_text(node))
          when Prism::LocalVariableReadNode then unknown_block_read_text(node)
          when Prism::MultiWriteNode then multi_write_text(node)
          when Prism::InstanceVariableOrWriteNode then instance_variable_or_text(node)
          when Prism::LocalVariableOrWriteNode then logic_write_text(node, "join_either")
          when Prism::LocalVariableAndWriteNode then logic_write_text(node, "join_both")
          when Prism::InstanceVariableWriteNode then instance_variable_write_text(node)
          when Prism::InstanceVariableOperatorWriteNode then change_text(node)
          when Prism::IndexOperatorWriteNode then place_change_text(node, index_text(node))
          when Prism::CallOperatorWriteNode then place_change_text(node, "#{rewritten_text(node.receiver)}.#{node.read_name}")
          when Prism::ReturnNode, Prism::BreakNode, Prism::NextNode then jump_text(node)
          when *OWN_SCOPES then own_scope_text(node)
          when Prism::StatementsNode then statements_text(node)
          else copied_text(node)
          end
        end

        # A statement with another after it has nothing reading its value, so a join there
        # needs no variable to keep its answer in.
        def statements_text(node)
          node.body[0...-1].each { |statement| @lone_joins[statement] = true }
          @open_statements.push([node, @open_tests.length])
          copied_text(node)
        ensure
          @open_statements.pop
        end

        # How many of the open tests, counted from the outermost, opened before +write+'s name was
        # last given a value outright by a line that every way to +write+ runs: a line of its own
        # among the statements +write+ stands in, or stands under, with no block between.
        #
        #     while more != 0          # the game's loop
        #       place = 0              # every round runs this
        #       while place < 4        # Ruby's loop, written out four times
        #         place += 1
        #
        # While the name still holds the plain value that line gave it, those tests have nothing
        # to follow: whichever way they go, the game reaches the write with the same value. A name
        # holding a game variable by then (one read after the test, so given a variable before it)
        # is changed under every test, as it always was. Writes.tests_followed decides which.
        def tests_open_before_plain_start(write)
          @open_statements.reverse_each do |statements, open_tests|
            return open_tests if statements.body.any? { |statement| gives_plain_value_before?(statement, write) }
          end
          0
        end

        def gives_plain_value_before?(statement, write)
          statement.is_a?(Prism::LocalVariableWriteNode) && statement.name == write.name &&
            statement.location.end_offset <= write.location.start_offset && @names.plain_name_write?(statement) &&
            !reads_local?(statement.value, write.name)
        end

        def reads_local?(node, name)
          return true if node.is_a?(Prism::LocalVariableReadNode) && node.name == name

          node.compact_child_nodes.any? { |child| reads_local?(child, name) }
        end

        # The node's text, with what is inside it rewritten. A heredoc's lines sit past the end
        # of the node that opened them, and the text around the node carries them, so they
        # are left out here. +from+ starts the copy further in, the children before it left out.
        def copied_text(node, from: node.location.start_offset)
          at = from
          ends = node.location.end_offset
          pieces = node.compact_child_nodes.sort_by { |child| child.location.start_offset }.map do |child|
            start = child.location.start_offset
            next "" if start < at || start >= ends

            piece = between(at, start) + rewritten_text(child)
            at = child.location.end_offset
            piece
          end
          pieces.join + between(at, node.location.end_offset)
        end

        # A `return` in a block belongs to that block, so tests open outside it do not apply.
        def own_scope_text(node)
          outer = @open_tests
          outer_block_tests = @block_tests
          outer_statements = @open_statements
          @block_tests = node.is_a?(Prism::DefNode) ? [] : @block_tests + outer
          @open_tests = []
          @open_statements = []
          @tail_ternaries[node.body.body.last] = true if method_body?(node)
          copied_text(node)
        ensure
          @open_tests = outer
          @block_tests = outer_block_tests
          @open_statements = outer_statements
        end

        def method_body?(node) = node.is_a?(Prism::DefNode) && node.body.is_a?(Prism::StatementsNode)

        def under_open_test(test, &block) = under_open_tests([test], &block)

        def under_open_tests(tests)
          outer = @open_tests
          @open_tests += tests
          yield
        ensure
          @open_tests = outer
        end

        # Plain Ruby jumps as it always has. Under a test the game makes, the step refuses it.
        # The `if true` is for Ruby's parser, which will not let a jump stand as a value.
        def jump_text(node)
          return copied_text(node) if @open_tests.empty?

          refusals = @open_tests.map { |test| "#{test}.refuse_jump!(:#{jump_word(node)})" }.join("; ")
          "(#{refusals}; if true then #{copied_text(node)} end)"
        end

        def call_text(node)
          note_tail_of_answering_block(node)
          return "#{STEPS}.opposite(#{argument(node.receiver)})" if node.name == :! && node.receiver
          return index_write_text(node) if node.name == :[]= && node.receiver
          return attribute_write_text(node) if node.attribute_write? && node.receiver
          return "#{STEPS}.nil_test(#{argument(node.receiver)})" if node.name == :nil? && node.receiver
          return nil_comparison_text(node) if LocalNames.nil_comparison?(node)
          return equality_text(node) if equality?(node)
          return bits_text(node) if Steps::BIT_JOINS.include?(node.name) && node.receiver && node.arguments
          return "self.#{copied_text(node)}" if node.receiver.nil? && @outer_locals.include?(node.name)

          copied_text(node)
        end

        # A verb that reads a number off its block's last line takes a ternary there as the
        # number, as a method's answer does. Any other block's last line is left as a statement,
        # since nothing reads it and keeping its value would add to the cartridge.
        def note_tail_of_answering_block(node)
          return unless ANSWERING_BLOCK_VERBS.include?(node.name) && node.block.is_a?(Prism::BlockNode)

          body = node.block.body
          note_tail_ternaries(body.body.last) if body.is_a?(Prism::StatementsNode)
        end

        # ...and so is a ternary ending a side of that one: `a ? 1 : b ? 2 : 3` picks from three.
        def note_tail_ternaries(node)
          return unless node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil?

          @tail_ternaries[node] = true
          [node.statements, node.subsequent&.statements].compact.each { |side| note_tail_ternaries(side.body.last) }
        end

        # `x == nil` and `x != nil`, either way round, are `x.nil?` and `!x.nil?`: Ruby's answer on a
        # plain value, and on a game variable that can hold nil, the test `nil?` makes as it plays.
        def nil_comparison_text(node)
          operand = LocalNames.side_not_nil(node)
          test = "#{STEPS}.nil_test(#{argument(operand)})"
          node.name == :== ? test : "#{STEPS}.opposite(#{test})"
        end

        # `a == b` or `a != b`, written with the operator between its two sides.
        def equality?(node)
          %i[== !=].include?(node.name) && node.receiver && node.call_operator_loc.nil? && node.block.nil? &&
            node.arguments&.arguments&.one?
        end

        # Ruby asks the left side, so Steps asks the right one where only it can make the test.
        def equality_text(node)
          step = node.name == :== ? "equal_test" : "unequal_test"
          "#{STEPS}.#{step}(#{argument(node.receiver)}, #{argument(node.arguments.arguments.first)})"
        end

        def bits_text(node)
          "#{STEPS}.bits(#{argument(node.receiver)}, :#{node.name}, #{argument(node.arguments.arguments.first)})"
        end

        def index_write_text(node)
          *keys, value = node.arguments.arguments.map { |each_argument| argument(each_argument) }
          slot_write_text(argument(node.receiver), keys, value, written_place(node, node.arguments))
        end

        def attribute_write_text(node)
          label = node.slice[/\A[^=]*/].strip
          attribute_write(argument(node.receiver), node.name.to_s.delete_suffix("="), argument(node.arguments.arguments.first), label)
        end

        def written_place(node, arguments) = "#{node.receiver.slice}[#{arguments.arguments[0...-1].map(&:slice).join(', ')}]"

        def fresh_name = "__plain_ruby_#{@answers += 1}"

        # Every write in the game comes to Writes.write through here. See that for what it decides.
        def write_call(read, value, label, assign: NEW_VALUE, options: "")
          "#{WRITES}.write(#{read}, #{value}, #{open_tests_text}, #{label.to_sym.inspect}#{options}) " \
            "{ |#{NEW_VALUE}| #{assign} }"
        end

        # The receiver and the keys are held, so what they are worked out from runs once.
        def slot_write_text(receiver, keys, value, label)
          holder = fresh_name
          held_keys = fresh_name
          held = fresh_name
          write = write_call("#{WRITES}.slot(#{holder}, #{held_keys}, #{held})", held, label,
                             assign: "#{holder}[*#{held_keys}] = #{NEW_VALUE}",
                             options: ", needs_slot: #{WRITES}.keeps_ruby_values?(#{holder})")
          "(#{holder} = #{receiver}; #{held_keys} = [#{keys.join(', ')}]; #{held} = #{value}; #{write})"
        end

        def attribute_write(receiver, name, value, label)
          holder = fresh_name
          held = fresh_name
          write = write_call("#{WRITES}.attribute(#{holder}, :#{name})", held, label, assign: "#{holder}.#{name} = #{NEW_VALUE}")
          "(#{holder} = #{receiver}; #{held} = #{value}; #{write})"
        end

        def index_text(node) = "#{rewritten_text(node.receiver)}[#{node.arguments ? rewritten_text(node.arguments) : ''}]"

        # `+=` on a place. The block is what Ruby would do, for a place that holds no variable.
        def place_change_text(node, place)
          label = between(node.location.start_offset, node.binary_operator_loc.start_offset).strip
          "#{WRITES}.change(#{place}, :#{node.binary_operator}, #{argument(node.value)}, #{open_tests_text}, " \
            "#{label.to_sym.inspect}) { |#{NEW_VALUE}| #{place} = #{NEW_VALUE} }"
        end

        # A plain number changed from inside a block no one can place: `each` may be Ruby's, which
        # runs now, or a pool's, which records game code. Only running it can tell, so the step
        # looks, using the question the block's builder answers.
        #
        # A name of the scope around a block, changed in it under a test the game makes, was given a
        # variable before the test if anything reads it after (LocalNames#plain_writes_in), and the
        # write goes to that under the tests open around the block. One nothing reads after is
        # Ruby's, since only code on that side reads it.
        #
        # A number changed from a block that may be a pool's `each` (LocalNames#from_unknown_block?)
        # is decided as each line runs. While the line records game code, the name is a game
        # variable: its first line sets it there, so a method called on every pass starts it
        # afresh, and a change from the block makes it one holding the number it has then. While
        # setting up it stays Ruby's, so `names.each { count += 1 }` over a Ruby list counts in Ruby.
        #
        # That number is decided before a promotion is: the name may be the game variable its own
        # line made by now, and a promoted write under a test decided while building would only
        # give the name a working-out of it, so a pool's `each` would add once whatever it holds.
        def guarded_write_text(node, written)
          return unknown_block_write_text(node) if @names.changed_from_unknown_block?(node)
          return under_open_tests(@block_tests) { write_or_change_text(node) } if promoted_in_block?(node)

          written
        end

        # A read of a number changed from a block only running can place, made from inside such a
        # block. A method made from a block may test the name before it changes it (`x += 1 if
        # shown == 0; shown = x`), so while game code is recorded the read makes it the game
        # variable too, or the test would be decided once, while building, from the number it held.
        def unknown_block_read_text(node)
          return copied_text(node) unless @names.read_from_unknown_block?(node)

          "(#{variable_while_recording_text(node)})"
        end

        def unknown_block_write_text(node)
          if @names.first_write?(node)
            prefix = between(node.location.start_offset, node.value.location.start_offset)
            return "#{prefix}#{WRITES}.start_variable_while_recording(self, (#{value_text(node.value)}), " \
                   ":#{@names.variable_name_of(node)}, #{RECORDING_TEST_SOURCE}#{source_option_text})"
          end

          tests = promoted_in_block?(node) ? @block_tests : []
          "(#{variable_while_recording_text(node)}; #{under_open_tests(tests) { variable_write_text(node) }})"
        end

        # The name made the game variable it is to be, if game code is being recorded as this runs.
        def variable_while_recording_text(node)
          "#{node.name} = #{WRITES}.variable_while_recording(self, #{node.name}, :#{@names.variable_name_of(node)}, " \
            "#{RECORDING_TEST_SOURCE}#{source_option_text})"
        end

        # The Ruby a rewritten line asks with: true where the builder records game code as the line
        # runs. A part of a game runs on no builder, so it answers false there.
        RECORDING_TEST_SOURCE = "(respond_to?(:recording_game_code?) && recording_game_code?)"

        def promoted_in_block?(node)
          !@block_tests.empty? && node.depth.positive? && @names.plain_name_write?(node) && @names.promoted?(node)
        end

        def write_or_change_text(node) = node.is_a?(Prism::LocalVariableOperatorWriteNode) ? change_text(node) : write_text(node)

        # The write of a name that may hold a game variable by now: Writes changes the variable if
        # it does, and leaves the write to Ruby if not.
        def variable_write_text(node)
          return "#{node.name} = #{change_call(node)}" if node.is_a?(Prism::LocalVariableOperatorWriteNode)

          "#{node.name} = #{assign_text(node.name, "(#{value_text(node.value)})")}"
        end

        # A part of a game keeps its variables in these, so one holding a game variable is changed.
        def instance_variable_write_text(node)
          prefix = between(node.location.start_offset, node.value.location.start_offset)
          value = value_text(node.value)
          return "#{prefix}#{WRITES}.keep_as_own(#{value})" if LocalNames.makes_variable?(node.value)

          copies = @names.moved_in_game_code?(node.name) ? ", copies: true" : ""
          "#{prefix}#{write_call(node.name, "(#{value})", node.name, options: ", moves: true#{copies}")}"
        end

        # `@x ||= var :x, 0`, the same as `@x = var :x, 0` the first time.
        def instance_variable_or_text(node)
          return copied_text(node) unless LocalNames.makes_variable?(node.value)

          "#{node.name} ||= #{WRITES}.keep_as_own(#{value_text(node.value)})"
        end

        def write_text(node)
          prefix = between(node.location.start_offset, node.value.location.start_offset)
          # A name kept for a read past its `if` can stay a plain name under a test further out, so
          # it keeps its answer the way any plain name does.
          return "#{prefix}#{second_name_write(node.name, "(#{promoted_value_text(node)})", node)}" if promoted?(node)
          return picked_into_text(node) if picks_into_variable?(node)
          return joined_into_text(node, prefix) if joins_into_variable?(node)

          case @names.action_for(node)
          # The line that makes a variable outside a game block sets it wherever it runs after
          # power-on (Writes.variable_set_where_reached).
          when :declare then "#{prefix}#{declaration(node, sets_where_reached: true)}"
          # The line that makes a variable in game code sets it on every pass, as Ruby would.
          when :start then "#{prefix}#{start_text(node)}"
          when :assign then "#{prefix}#{assign_text(node.name, "(#{value_text(node.value)})")}"
          else "#{prefix}#{noted_if_handed(node, kept_value_text(node.value, node))}"
          end
        end

        def promoted_value_text(node) = @names.read_after_it_changes?(node) ? kept_value_text(node.value, node) : value_text(node.value)

        # A write to a plain name that already holds something, which may turn out to be a game
        # variable it was handed (Writes.note_handed_name_written). The name's first line holds
        # nothing yet, unless it is an argument, whose first write comes after it was given one.
        def noted_if_handed(node, value)
          return value unless @names.holds_before_write?(node)

          held = fresh_name
          "(#{held} = #{value}; #{WRITES}.note_handed_name_written(#{node.name}, #{held}, :#{node.name}); #{held})"
        end

        def start_text(node)
          return declaration(node) if @names.keeps_truth?(node)

          "#{WRITES}.give_variable(#{declaration(node)}, #{rewritten_text(node.value)})"
        end

        # Anything but a number written out can hold anything, so what it starts is asked as the
        # line runs. Its value is kept in a local of its own, so the right side runs once.
        def declaration(node, sets_where_reached: false)
          name = @names.variable_name_of(node)
          if @names.keeps_truth?(node)
            reached = "#{WRITES}.reached_after_power_on?(self, :#{name}, #{@source_label.inspect})"
            return "#{WRITES}.start_with_truth(#{value_text(node.value)}, reached: #{reached}) " \
                   "{ |start| #{made_variable_text(name, 'start')} }"
          end
          return declared_variable_text(name, "false", sets_where_reached) if node.value.is_a?(Prism::NilNode)
          return declared_variable_text(name, rewritten_text(node.value), sets_where_reached) if LocalNames.number?(node)

          start = "__plain_ruby_#{@answers += 1}"
          "(#{start} = #{value_text(node.value)}; #{WRITES}.start_name(#{start}) " \
            "{ |start, sets| #{declared_variable_text(name, 'start', sets_where_reached, 'sets')} })"
        end

        # +sets+ is the Ruby that answers whether the start is all the line gives the name.
        def declared_variable_text(name, start, sets_where_reached, sets = nil)
          return made_variable_text(name, start) unless sets_where_reached

          "#{WRITES}.variable_set_where_reached(self, :#{name}, #{start}#{", sets: #{sets}" if sets}#{source_option_text})"
        end

        def kept_value_text(value, write = nil)
          return "#{STEPS}.kept_answer((#{value_text(value)}))" if write && @names.read_after_it_changes?(write)
          return value_text(value) unless value.is_a?(Prism::LocalVariableReadNode) && @names.variable_read?(value)

          "#{STEPS}.copy_of_variable(#{rewritten_text(value)})"
        end

        def value_text(value)
          return "(#{value_text(lone_statement(value))})" if lone_statement(value)
          return case_text(value, kept: true) if asked_arm_by_arm?(value)

          conditional = value.is_a?(Prism::IfNode) || value.is_a?(Prism::UnlessNode)
          conditional ? conditional_text(value, kept: true) : rewritten_text(value)
        end

        # `x ||= value`. On a game variable it is `x = x || value`, so a yes or no is set as the
        # game plays. A plain name is left to Ruby.
        def logic_write_text(node, step)
          joined = "#{STEPS}.#{step}(#{node.name}) { #{rewritten_text(node.value)} }"
          return "#{node.name} = #{second_name_write(node.name, joined, node)}" if promoted?(node)
          return copied_text(node) unless @names.action_for(node)

          "#{node.name} = #{assign_text(node.name, joined)}"
        end

        # A name #promote gave a variable of its own, if a test the game makes turned out to be open.
        # +write+ is the line's own node, where it has one to look for an earlier line with.
        def second_name_write(name, value, write = nil) = write_call(name, value, name, options: second_name_options(write))

        def second_name_options(write)
          before_plain_start = write ? tests_open_before_plain_start(write) : 0
          before_plain_start.zero? ? ", second_name: true" : ", second_name: true, before_plain_start: #{before_plain_start}"
        end

        # `a, b = b, a`. Every right side is held in a name of its own, then each target is given
        # its own, one write at a time, so each goes the way the same line alone would. A right
        # side reading a target already written has to be kept first, or it would see the new
        # number: that is the one place a swap needs a hidden variable.
        # Ruby does the unpacking, `*` and nested names included, into names of its own. Each
        # target then goes the way one line would, looking at what it was given, so sprites stay
        # sprites and a number given to a game variable changes it.
        def multi_write_text(node)
          held = []
          shape = targets_shape(node, held)
          writes = held.map { |target, value| target_write_text(target, value) }
          "(#{shape} = #{multi_write_values(node)}; #{writes.join('; ')}; [#{held.map(&:last).join(', ')}])"
        end

        # The left of the assignment with a name of its own for each target, which go in +held+.
        def targets_shape(node, held)
          parts = node.lefts.map { |target| target_shape(target, held) }
          parts << rest_shape(node.rest, held) if node.rest
          parts += node.rights.map { |target| target_shape(target, held) }
          parts.join(", ")
        end

        def target_shape(target, held)
          return "(#{targets_shape(target, held)})" if target.is_a?(Prism::MultiTargetNode)

          name = "__plain_ruby_#{@answers += 1}"
          held << [target, name]
          name
        end

        def rest_shape(rest, held)
          return "*" unless rest.is_a?(Prism::SplatNode) && rest.expression

          "*#{target_shape(rest.expression, held)}"
        end

        def multi_write_values(node)
          values = node.value
          flat = node.rest.nil? && node.rights.empty? && node.lefts.none?(Prism::MultiTargetNode)
          return rewritten_text(values) unless flat && values.is_a?(Prism::ArrayNode) && values.opening_loc.nil? &&
                                               values.elements.length == node.lefts.length

          values.elements.each_with_index.map do |value, index|
            text = value_text(value)
            reads_target?(value, node.lefts.first(index)) ? "#{STEPS}.number_now(#{text})" : text
          end.join(", ")
        end

        def reads_target?(value, targets)
          names = targets.filter_map { |target| target.name if target.respond_to?(:name) }
          reads = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode]
          return true if reads.any? { |kind| value.is_a?(kind) } && names.include?(value.name)

          value.compact_child_nodes.any? { |child| reads_target?(child, targets) }
        end

        def target_write_text(target, value)
          case target
          when Prism::LocalVariableTargetNode then local_target_text(target, value)
          when Prism::InstanceVariableTargetNode
            "#{target.name} = #{write_call(target.name, value, target.name, options: ", moves: true")}"
          when Prism::IndexTargetNode
            keys = target.arguments&.arguments.to_a.map { |key| argument(key) }
            slot_write_text(argument(target.receiver), keys, value, target.slice)
          when Prism::CallTargetNode
            attribute_write(argument(target.receiver), target.name.to_s.delete_suffix("="), value, target.slice)
          else "#{target.slice} = #{value}"
          end
        end

        def local_target_text(target, value)
          name = target.name
          return "#{name} = #{second_name_write(name, value)}" if promoted?(target)

          case @names.action_for(target)
          # One name of `count, other = 0, 0`. Its line sets it wherever it runs after power-on,
          # in game code and outside it (Writes.variable_set_where_reached).
          when :declare, :start
            made = declared_variable_text(@names.variable_name_of(target), "start", true, "sets")
            "#{name} = #{WRITES}.start_name(#{value}) { |start, sets| #{made} }"
          when :assign then "#{name} = #{assign_text(name, value)}"
          else "#{name} = #{value}"
          end
        end

        def made_variable_text(name, start) = "#{WRITES}.variable_with_no_var_line(self, :#{name}, #{start}#{source_option_text})"

        # Which source a made variable's local belongs to (Writes.variable_with_no_var_line).
        def source_option_text = @source_label ? ", source: #{@source_label.inspect}" : ""

        def assign_text(name, value) = write_call(name, value, name)

        def promoted?(node) = @names.promoted?(node) && !@open_tests.empty?

        def open_tests_text = "[#{@open_tests.join(', ')}]"

        # What stands before a side's code: each name it changes given a variable, if the test
        # turns out to be the game's. There it goes before the branch, where the name's number
        # still holds whichever way the test goes. +outer+ are tests already open around this one.
        def promotions_text(node, sides, answer, outer: @open_tests)
          given = [answer, *outer].join(", ")
          names = @names.names_to_promote(node, sides).map do |name|
            stays = @names.written_on_every_side?(name, sides) ? "" : ", may_stay_nil: true"
            "#{name} = #{WRITES}.promote(#{name}, #{given}#{stays}); "
          end
          (names + @names.places_changed_in(sides).filter_map { |place| place_promotion_text(place, given) }).uniq.join
        end

        # The same for an instance variable, a slot or an attribute, which any method can read, so
        # nothing can show it is not read afterwards. A place written some other way than by a plain name
        # and plain keys is left: if it turns out to need following, Writes.write stops the build.
        def place_promotion_text(place, given)
          case place
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode
            "#{place.name} = #{WRITES}.promote_place(#{place.name}, #{given}, may_stay_nil: true); "
          when Prism::IndexOperatorWriteNode then slot_promotion_text(place, place.arguments.arguments, given)
          when Prism::CallOperatorWriteNode then attribute_promotion_text(place, place.read_name, given)
          else
            return slot_promotion_text(place, place.arguments.arguments[0...-1], given) if place.name == :[]=

            attribute_promotion_text(place, place.name.to_s.delete_suffix("="), given)
          end
        end

        def slot_promotion_text(place, keys, given)
          return unless keys.all? { |key| LocalNames.plain_key?(key) }

          promotion = "#{WRITES}.promote_slot(#{place.receiver.slice}, [#{keys.map(&:slice).join(', ')}], #{given})"
          text_once_names_exist(promotion, [place.receiver, *keys])
        end

        def attribute_promotion_text(place, name, given)
          text_once_names_exist("#{WRITES}.promote_attribute(#{place.receiver.slice}, :#{name}, #{given})", [place.receiver])
        end

        # +text+ stands before a branch, and +parts+ are written inside it. A local that branch is
        # first to give does not exist yet up here, and has nothing to promote. `defined?` asks Ruby
        # itself, so a name an earlier side gave, which a game test's both sides run, still counts.
        # It must answer "local-variable": up here `box` would otherwise be the builder's verb.
        def text_once_names_exist(text, parts)
          names = parts.grep(Prism::LocalVariableReadNode).map { |local| "defined?(#{local.slice}) == 'local-variable'" }.uniq
          names.empty? ? "#{text}; " : "#{text} if #{names.join(' && ')}; "
        end

        def change_text(node)
          return "#{node.name} = #{change_call(node, second_name_options(node))}" if promoted?(node)
          if @names.plain_name_write?(node)
            return "(#{WRITES}.note_handed_name_written(#{node.name}, nil, :#{node.name}); #{copied_text(node)})"
          end

          "#{node.name} = #{change_call(node)}"
        end

        def change_call(node, options = "")
          "#{WRITES}.change(#{node.name}, :#{node.binary_operator}, #{argument(node.value)}, #{open_tests_text}, " \
            "#{node.name.to_sym.inspect}#{options}) { |#{NEW_VALUE}| #{NEW_VALUE} }"
        end

        # The right side is a block so plain values keep Ruby's skipping of it.
        def joined_text(node, step, into: nil)
          jump = jump_in(node.right)
          return jump_after_join_text(node, step, jump) if jump

          given = @lone_joins.key?(node) ? ", used: false" : ""
          given = ", into: #{into}" if into
          return join_under_test_text(node, step, given) if @names.changes_under?(node, [node.right])

          "#{STEPS}.#{step}(#{argument(node.left)}#{given}) { #{rewritten_text(node.right)} }"
        end

        # `a > 3 && x = 2`: the right side is a side of a test, so a name it changes is given a
        # variable first, as on a side of an `if`.
        def join_under_test_text(node, step, given)
          left = "__plain_ruby_#{@answers += 1}"
          promotions = promotions_text(node, [node.right], left)
          right = under_open_test(left) { rewritten_text(node.right) }
          "(#{left} = #{STEPS}.side_of_join(#{argument(node.left)}); #{promotions}" \
            "#{STEPS}.#{step}(#{left}.value#{given}) { #{right} })"
        end

        # `found or next`. The right side of a join goes in a block, and a `next` or `break` in that
        # block would leave only it, so a join that jumps is written out with no block at all.
        def jump_after_join_text(node, step, jump)
          left = "__plain_ruby_#{@answers += 1}"
          right = "(#{rewritten_text(node.right)})"
          sides = step == "join_either" ? "#{left} : #{right}" : "#{right} : #{left}"
          "(#{left} = #{argument(node.left)}; #{STEPS}.answer_before_jump(#{left}, :#{jump_word(jump)}) ? #{sides})"
        end

        # The jump this node would make from where it stands. A block of its own keeps its jumps.
        def jump_in(node)
          return node if JUMPS.any? { |kind| node.is_a?(kind) }
          return if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          node.compact_child_nodes.filter_map { |child| jump_in(child) }.first
        end

        def jump_word(node) = node.class.name.split("::").last.delete_suffix("Node").downcase

        # A value handed to a step. The parentheses are for a call written without its own, like
        # `actions = menu :actions do ... end`, which Ruby takes alone but not as an argument.
        def argument(node) = "(#{rewritten_text(node)})"

        # A real `while`: a plain test goes round as usual, and a game test's body runs once,
        # recording itself into a loop the game makes. `begin ... end while` runs its body first,
        # before the test is asked, so that once is plain Ruby whatever the test turns out to be,
        # and a name it changes is given its variable as the loop opens, holding that first answer.
        def loop_text(node, step)
          test = "__plain_ruby_#{@answers += 1}"
          shut_at = node.closing_loc&.start_offset || node.location.end_offset
          promotions = promotions_text(node, [node.statements], test)
          body = under_open_test(test) { side_body_text(node, shut_at) }
          first = node.begin_modifier? ? "#{body}; " : ""
          "(#{test} = #{STEPS}.#{step} { #{rewritten_text(node.predicate)} }; #{first}" \
            "while #{test}.go_round#{" { #{promotions} }" unless promotions.empty?}; #{body}; end)"
        end

        # What a pair of parentheses holds, when that is one conditional.
        def lone_statement(value)
          return unless value.is_a?(Prism::ParenthesesNode) && value.body.is_a?(Prism::StatementsNode)

          only = value.body.body
          only.first if only.one? && (only.first.is_a?(Prism::IfNode) || only.first.is_a?(Prism::UnlessNode))
        end

        # A conditional as two real `if`s, one for each side. A plain test takes one; a game
        # test takes both, once each. +kept+ is for one whose value is used, by `x = ...`.
        def conditional_text(node, kept: false)
          # A ternary is written for its value, so one ending a method is that method's answer.
          kept = :tail if @tail_ternaries.key?(node) && node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil?
          return nested_conditional_text(node) if nestable?(node, kept)

          answer = "__plain_ruby_#{@answers += 1}"
          shut_at = node.end_keyword_loc&.start_offset || node.location.end_offset
          promotions = promotions_text(node, [node.statements, other_side(node)], answer)
          sides = under_open_test(answer) do
            "#{yes_side_text(node, answer, shut_at, kept)}#{no_side_text(node, answer, shut_at, kept)}"
          end
          "(#{answer} = #{STEPS}.branch_test(#{test_text(node)}); #{promotions}#{sides}#{answer}.#{value_step(kept)})"
        end

        def value_step(kept)
          return "tail_value" if kept == :tail

          kept && !kept.is_a?(String) ? "picked_value" : "answer"
        end

        # `case` as a chain of tests. Each `when` is asked in turn, in Ruby's way on a plain value
        # and as a test on a number the game keeps, and each arm stands in the no side of the one
        # before it, so an arm that runs changes nothing the next asks about.
        def case_text(node, kept: false)
          subject = "__plain_ruby_#{@answers += 1}"
          opened = (node.predicate || node).location
          given = node.predicate ? "#{subject} = #{rewritten_text(node.predicate)}; " : ""
          breaks = line_ends_between(node.predicate ? opened.end_offset : opened.start_offset, node.conditions.first.location.start_offset)
          "(#{given}#{breaks}#{arm_text(node, 0, subject, kept)})"
        end

        def arm_text(node, index, subject, kept)
          arm = node.conditions[index]
          return else_arm_text(node) if arm.nil?

          answer = "__plain_ruby_#{@answers += 1}"
          promotions = promotions_text(node, node.conditions.drop(index).map(&:statements) + [node.else_clause], answer)
          ends = (node.conditions[index + 1] || node.else_clause)&.location&.start_offset || node.end_keyword_loc.start_offset
          sides = under_open_test(answer) do
            yes = arm_body_text(arm, ends)
            rest = node.conditions[index + 1] || node.else_clause ? arm_text(node, index + 1, subject, kept) : nil
            "if #{answer}.open_yes_side; #{side_close_text(answer, kept, yes)}; end; " \
              "#{"if #{answer}.open_no_side; #{side_close_text(answer, kept, rest)}; end; " if rest}"
          end
          "(#{answer} = #{STEPS}.branch_test(#{when_test_text(node, arm, subject)}); #{promotions}#{sides}" \
            "#{answer}.#{value_step(kept)})"
        end

        def arm_body_text(arm, ends)
          opened = (arm.is_a?(Prism::InNode) ? arm.pattern : arm.conditions.last).location.end_offset
          arm.statements ? side_text(opened, arm.statements, ends) : line_ends_between(opened, ends)
        end

        # What an arm is asked about: a `when`'s values, or the choices of an `in`'s pattern.
        def arm_choices(arm) = arm.is_a?(Prism::InNode) ? pattern_choices(arm.pattern) : arm.conditions

        # A pattern a `when` could have been written with: values, ranges and constants, and
        # `a | b` between them. Anything else (a binding, an array or hash pattern, a guard) is
        # nil, and the `case` is Ruby's own.
        def pattern_choices(pattern)
          return [pattern] if WHEN_VALUES.any? { |kind| pattern.is_a?(kind) }
          return unless pattern.is_a?(Prism::AlternationPatternNode)

          sides = [pattern_choices(pattern.left), pattern_choices(pattern.right)]
          sides.flatten if sides.all?
        end

        # Is this a `case` the rewrite asks arm by arm: one with `when`, or one with `in` written as
        # a `when` would be?
        def asked_arm_by_arm?(node)
          return true if node.is_a?(Prism::CaseNode)

          node.is_a?(Prism::CaseMatchNode) && !node.predicate.nil? && node.conditions.all? { |arm| pattern_choices(arm.pattern) }
        end

        # `case ... in`. Written as a `when` would be, it is one, and a number the game keeps can
        # be asked about it. Any other pattern is Ruby's, which matches it while the game is built,
        # so only a plain value can be its subject: Steps.plain_pattern_subject refuses a number the
        # game keeps.
        def case_match_text(node)
          return case_text(node) if asked_arm_by_arm?(node)

          node.conditions.each { |arm| @written_as_is[arm.pattern] = true }
          @pattern_subjects[node.predicate] = true if node.predicate
          copied_text(node)
        end

        # `#{...}` in a String or a Symbol. Ruby puts the piece into the text while the game is
        # built, so Steps.text_piece refuses a number the game keeps, which has no digits yet.
        def embedded_text(node)
          return copied_text(node) if node.statements.nil?

          "\#{#{STEPS}.text_piece((#{rewritten_text(node.statements)}))}"
        end

        # `for x in list`. Ruby runs it while the game is built, as it runs `each`. A range with a
        # number the game keeps at an end has no length yet, so Steps.for_range refuses it, and
        # Steps.for_collection refuses a game's own list or pool, whose items the game holds.
        def for_text(node)
          collection = node.collection
          unless collection.is_a?(Prism::RangeNode)
            return between(node.location.start_offset, collection.location.start_offset) +
                   "#{STEPS}.for_collection(#{argument(collection)})" +
                   copied_text(node, from: collection.location.end_offset)
          end

          from = collection.left ? argument(collection.left) : "nil"
          upto = collection.right ? argument(collection.right) : "nil"
          range = "#{STEPS}.for_range(#{from}, #{upto}, #{collection.exclude_end?})"
          between(node.location.start_offset, collection.location.start_offset) + range +
            copied_text(node, from: collection.location.end_offset)
        end

        def else_arm_text(node)
          other = node.else_clause
          opened = other.else_keyword_loc.end_offset
          shut_at = node.end_keyword_loc.start_offset
          other.statements ? side_text(opened, other.statements, shut_at) : line_ends_between(opened, shut_at)
        end

        def when_test_text(node, arm, subject)
          choices = arm_choices(arm)
          return "#{STEPS}.when_test(#{subject}, #{choices.map { |choice| rewritten_text(choice) }.join(', ')})" if node.predicate

          *others, last = choices
          others.reverse.reduce(argument(last)) { |rest, choice| "#{STEPS}.join_either(#{argument(choice)}) { #{rest} }" }
        end

        # `if a && b` with no other side is one `if` inside another. So the right side is really
        # skipped when the left fails, as in Ruby, and nothing has to keep the join's answer.
        def nestable?(node, kept)
          !kept && node.is_a?(Prism::IfNode) && node.predicate.is_a?(Prism::AndNode) && node.subsequent.nil?
        end

        def nested_conditional_text(node)
          tests = tests_joined_by_and(node.predicate)
          answers = tests.map { "__plain_ruby_#{@answers += 1}" }
          shut_at = node.end_keyword_loc&.start_offset || node.location.end_offset
          outers = answers.each_index.map { |index| @open_tests + answers.first(index) }
          promotions = answers.zip(outers).map { |answer, outer| promotions_text(node, [node.statements], answer, outer: outer) }
          body = under_open_tests(answers) { side_body_text(node, shut_at) }
          tests.zip(answers, promotions).reverse.reduce(body) do |inner, (test, answer, promoted)|
            before = test.equal?(tests.first) ? "" : line_ends_before_test(tests, test)
            "(#{before}#{answer} = #{STEPS}.branch_test(#{argument(test)}); #{promoted}" \
              "if #{answer}.open_yes_side; #{answer}.close_side((#{inner})); end; #{answer}.answer)"
          end
        end

        def tests_joined_by_and(node)
          return [node] unless node.is_a?(Prism::AndNode) && !jump_in(node.right)

          tests_joined_by_and(node.left) + tests_joined_by_and(node.right)
        end

        # A line break in the test stays one, so the lines after it keep their numbers.
        def line_ends_before_test(tests, test)
          line_ends_between(tests[tests.index(test) - 1].location.end_offset, test.location.start_offset)
        end

        def side_body_text(node, ends)
          statements = node.statements
          opened = node.predicate.location.end_offset
          if statements && statements.location.start_offset < node.predicate.location.start_offset
            rewritten_text(statements)
          elsif statements then side_text(opened, statements, ends)
          else line_ends_between(opened, ends)
          end
        end

        def test_text(node)
          node.is_a?(Prism::UnlessNode) ? "#{STEPS}.opposite(#{argument(node.predicate)})" : argument(node.predicate)
        end

        def other_side(node) = node.is_a?(Prism::UnlessNode) ? node.else_clause : node.subsequent

        # How a side ends. +kept+ marks what its value is for: nothing, the value of the whole
        # conditional, a method's answer (:tail), or the name of a game variable to go straight
        # into, which needs nothing to hold it on the way.
        def side_close_text(answer, kept, body)
          return "#{answer}.store_side(#{kept}, (#{body}))" if kept.is_a?(String)
          return "#{answer}.keep_tail_value((#{body}))" if kept == :tail

          "#{answer}.#{kept ? 'keep_side_value' : 'close_side'}((#{body}))"
        end

        # `x = test ? a : b` on a game variable is `if test then x = a else x = b end`. It takes
        # an answer on every side, since a side with none leaves nothing to store.
        def picks_into_variable?(write)
          return false if @names.keeps_truth?(write) || !answers_on_every_side?(write.value)

          %i[assign start].include?(@names.action_for(write)) && !@names.first_write?(write)
        end

        def answers_on_every_side?(value)
          case value
          when Prism::CaseNode, Prism::CaseMatchNode then asked_arm_by_arm?(value) && !value.else_clause.nil?
          when Prism::IfNode
            value.subsequent.is_a?(Prism::ElseNode) || (value.subsequent && answers_on_every_side?(value.subsequent))
          when Prism::UnlessNode then !value.else_clause.nil?
          else false
          end
        end

        # `done = a && work` on a game variable keeps the join's answer in `done` itself.
        def joins_into_variable?(write)
          [Prism::AndNode, Prism::OrNode].any? { |kind| write.value.is_a?(kind) } && !jump_in(write.value.right) &&
            @names.action_for(write) == :assign && !@names.keeps_truth?(write)
        end

        def joined_into_text(write, prefix)
          name = write.name
          step = write.value.is_a?(Prism::AndNode) ? "join_both" : "join_either"
          "#{prefix}#{assign_text(name, joined_text(write.value, step, into: name))}"
        end

        def picked_into_text(write)
          name = write.name.to_s
          text = asked_arm_by_arm?(write.value) ? case_text(write.value, kept: name) : conditional_text(write.value, kept: name)
          "#{name} = (#{text}; #{name})"
        end

        def yes_side_text(node, answer, shut_at, kept)
          body = side_body_text(node, other_side(node)&.location&.start_offset || shut_at)
          "if #{answer}.open_yes_side; #{side_close_text(answer, kept, body)}; end; "
        end

        def no_side_text(node, answer, shut_at, kept)
          other = other_side(node)
          return "" unless other

          body = if other.is_a?(Prism::ElseNode)
                   opened = other.else_keyword_loc.end_offset
                   statements = other.statements
                   statements ? side_text(opened, statements, shut_at) : line_ends_between(opened, shut_at)
                 else
                   "#{conditional_text(other, kept: kept)}#{line_ends_between(other.location.end_offset, shut_at)}"
                 end
          "if #{answer}.open_no_side; #{side_close_text(answer, kept, body)}; end; "
        end

        # One side's statements. What follows them is kept as written, because a heredoc's
        # lines sit there, past the end of the statement that opened it.
        def side_text(opened, statements, ends)
          "#{line_ends_between(opened, statements.location.start_offset)}#{rewritten_text(statements)}" \
            "#{between(statements.location.end_offset, ends)}"
        end
      end
    end
  end
end
