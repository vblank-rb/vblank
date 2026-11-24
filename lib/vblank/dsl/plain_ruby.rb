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
    # Nothing here guesses a type. Whether `if hp > 0` is a test for the game or for the build
    # cannot be read off the source, so each construct becomes a small step (PlainRuby::Steps)
    # that looks at the value as the block runs: `if console == :gbc` stays plain Ruby.
    #
    # A branch's code stays where it was written, inside parentheses in a real Ruby `if`, and is
    # never moved into a block. So the locals it sets outlive it and every line keeps its
    # number, which is what makes an error name the author's own line.
    module PlainRuby # :nodoc: all
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
      # This runs as the game is declared, because the block's binding is only there to read until
      # a game is made shareable between Ractors (Cartridge::Game#shareable_if_possible). The proc
      # this makes is cut loose in its place, so everything it needs later is written into it.
      #
      # +checked+ false leaves the checks out, for a block that has good reason to reach further
      # than a game does: a test's, which names its own helpers.
      def rewrite(block, allow: [], checked: true)
        file, line = block.source_location
        rewriter = Rewriter.new(*source_and_block_of(block), outer_locals: block.binding.local_variables,
                                                             source_label: "#{file}:#{line}",
                                                             follows_instance_variables: !library_file?(file))
        code = callable_source(rewriter, block)
        source = checked ? checked_source(rewriter, code, file, allow) : code
        eval(source, block.binding, file, line) # rubocop:disable Security/Eval
      end

      # What a game runs for +block+: the block rewritten, or as it is if it cannot be, as with one
      # made from a method, or one this module made already.
      def game_block(block, allow: [])
        refuse_block_with_no_file!(block)
        refuse_shareable_block_with_game_code!(block)
        rewritable?(block) ? rewrite(block, allow: allow, checked: game_blocks_checked?) : block
      end

      # A block made shareable between ractors (`Ractor.make_shareable`) is cut loose from the
      # scope it was written in, and Ruby then gives out no binding for it, so it cannot be
      # rewritten: run as it stands, `x += 1` changes a Ruby local and nothing in the game, and an
      # `if` on a game number is decided once, while building. A test class's constants are made
      # shareable (Testing::InRactors), so a block kept in one did exactly that, with no error.
      # A block whose source reads the same rewritten has nothing to lose, and runs as it is.
      def refuse_shareable_block_with_game_code!(block)
        return unless Ractor.shareable?(block) && file_block?(block)

        source, node = source_and_block_of(block)
        return if Rewriter.new(source, node, follows_instance_variables: !library_file?(block.source_location.first))
                          .rewritten_block == node.slice

        file, line = block.source_location
        raise Refused, "The block at #{File.basename(file)}:#{line} is shareable between Ractors, so VBlank cannot " \
                       "read it as normal Ruby. Its game code, such as `+=` or `if` on a game number, will do " \
                       "nothing in the game. In a test, a constant makes the block it keeps shareable. To fix this, " \
                       "return the block from a method, not from a constant."
      end

      # Whether +block+ was written in a file, not made by `eval` or by this module.
      def file_block?(block)
        iseq = RubyVM::InstructionSequence.of(block)
        !iseq&.absolute_path.nil? && File.file?(iseq.absolute_path)
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
      #
      # A game block whose code may change instance variables of its own marks them on the
      # builder it runs on before its first line (InstanceVariables.mark_changing), as a class
      # marks its own at the end of its body.
      def callable_source(rewriter, block)
        return rewriter.rewritten_block if rewriter.block_node.is_a?(Prism::LambdaNode)

        code = "#{block.lambda? ? 'lambda' : 'proc'} #{rewriter.rewritten_block}"
        return code if block.lambda?

        changing = rewriter.changing_instance_variables
        attributes = rewriter.changing_attributes
        file = File.expand_path(block.source_location.first)
        marks = "#{Rewriter::INSTANCE_VARIABLES}.note_game_file(self, #{file.inspect}); "
        unless changing.empty? && attributes.empty?
          marks += "#{Rewriter::INSTANCE_VARIABLES}.mark_changing(self, #{changing.inspect}, attributes: #{attributes.inspect}); "
        end
        "proc { |*__plain_ruby_given| #{marks}(#{code}).call(*__plain_ruby_given) }"
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
        return false unless file_block?(block)

        block.binding
        true
      rescue ArgumentError
        false
      end

      # What the block's source is rewritten into, for reading and for a test.
      def rewritten_source(block)
        follows = !library_file?(block.source_location.first)
        Rewriter.new(*source_and_block_of(block), follows_instance_variables: follows).rewritten_block
      end

      # Is +path+ a file of VBlank's own library? Its objects keep the build's own workings in their
      # instance variables, which are never the game's (InstanceVariables).
      def library_file?(path) = File.expand_path(path).start_with?(BlockChecks.library_folder)

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
        library = library_file?(path)
        CallChanges.record_game_method_names(root) unless library
        rewriter = Rewriter.new(source, source_label: File.expand_path(path), follows_instance_variables: !library)
        rewritten = "#{opening}#{rewriter.rewritten(root)}"
        return rewritten if library

        InstanceVariables.record_changing_attributes(File.expand_path(path), rewriter.changing_attributes)

        checks = BlockChecks.new(root, file: path, allow: [])
        checks.refuse_outside_calls_in_file!
        "#{rewritten}\n#{checks.file_constant_check(loaded_from: loaded_from)}\n"
      end

      # The block's source with its constructs written out as calls. It builds new text rather
      # than editing in place, since a trailing `if` is evaluated before what stands to its left.
      class Rewriter
        STEPS = "::VBlank::DSL::PlainRuby::Steps"
        WRITES = "::VBlank::DSL::PlainRuby::Writes"
        INSTANCE_VARIABLES = "::VBlank::DSL::PlainRuby::InstanceVariables"
        ARRAYS = "::VBlank::DSL::PlainRuby::Arrays"
        COUNTS = "::VBlank::DSL::PlainRuby::Counts"
        LOOP_JUMPS = "::VBlank::DSL::PlainRuby::Jumps"
        # The loops written as Ruby syntax, whose bodies keep their own `break` and `next`.
        LOOP_NODES = [Prism::WhileNode, Prism::UntilNode, Prism::ForNode].freeze
        # The jump target of a `begin ... end while` body, which is no loop's on its first round.
        DO_WHILE_TARGET = :do_while
        # Ruby's counting loops on a number, which Counts answers (#counted_loop_text).
        COUNTING_LOOPS = %i[times upto downto step].freeze
        NEW_VALUE = "__plain_ruby_new"
        JUMPS = [Prism::ReturnNode, Prism::BreakNode, Prism::NextNode].freeze

        # Values written out, which a jump can hand back without recording anything.
        LITERALS = [Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::IntegerNode, Prism::FloatNode,
                    Prism::SymbolNode, Prism::StringNode].freeze

        attr_reader :block_node

        # +outer_locals+ are the names the block's scope holds. Written further down the method a
        # block sits in, one is no local to the block as Ruby first read it, and yet it is to
        # `eval`: `screen :tiled` would stop being a call. Those calls are written with `self.`.
        #
        # +source_label+ names the block or file, so a local of its own keeps a variable of its own
        # beside a local of the same name in another (Builder#plain_local_variable). Nil for a
        # rewrite only read, never run.
        #
        # +follows_instance_variables+ sends every instance variable read and written through
        # InstanceVariables, which follows those the game names. VBlank's own files go without it.
        def initialize(source, block_node = nil, outer_locals: [], source_label: nil, follows_instance_variables: false)
          @source = source
          @block_node = block_node
          @outer_locals = outer_locals
          @source_label = source_label
          @follows_instance_variables = follows_instance_variables
          @whole_statements = {}.compare_by_identity # Nodes that stand as statements of their own
          @in_text = 0
          @answers = 0
          @open_tests = []
          @lone_joins = {}.compare_by_identity
          @tail_ternaries = {}.compare_by_identity
          @answer_tails = {}.compare_by_identity # Last lines whose value is an answer: a method's, an answering block's
          @block_tests = []
          # The patterns of a `case ... in` left to Ruby, which are Ruby's own syntax and not
          # expressions to rewrite, and the subjects such a `case` asks about.
          @written_as_is = {}.compare_by_identity
          @pattern_subjects = {}.compare_by_identity
          @heredoc_parts = []
          # Each run of statements being rewritten, the outermost first, with how many tests were
          # open as it began. A block, a lambda or a method starts with none.
          @open_statements = []
          # The loops around what is being rewritten, the innermost last (#with_jump_target), and
          # the blocks of counting loops and `loop do` that are loops of their own (#counted_loop_text).
          @jump_targets = []
          @jump_target_blocks = {}.compare_by_identity
          @set_in_routines = Set.new
          @nil_failing_reads = {}
        end

        def rewritten_block = rewritten(@block_node)

        def outside_writes = @names.outside_writes

        def rewritten(node)
          # Only VBlank's own files go without following instance variables (PlainRuby.library_file?).
          @names = LocalNames.new(node, library_file: !@follows_instance_variables)
          @promotion = @names.promotion
          @heredoc_parts = heredoc_parts_in(node).sort_by { |part| part.location.start_offset }
          @own_classes = @block_node ? own_classes_in(node) : Set.new
          @set_in_routines = instance_variables_set_in_routines(node)
          @nil_failing_reads = @set_in_routines.empty? ? {} : nil_failing_reads(node)
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
          when Prism::IfNode, Prism::UnlessNode then conditional_text(node, kept: ternary_read?(node))
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
          when Prism::InstanceVariableAndWriteNode then instance_variable_logic_text(node, "join_both")
          when Prism::LocalVariableOrWriteNode
            kept_local?(node) ? kept_part_text(node, "nil") : logic_write_text(node, "join_either")
          when Prism::LocalVariableAndWriteNode then logic_write_text(node, "join_both")
          when Prism::InstanceVariableReadNode then instance_variable_read_text(node)
          when Prism::DefinedNode then defined_text(node)
          when Prism::InstanceVariableWriteNode then instance_variable_write_text(node)
          when Prism::InstanceVariableOperatorWriteNode then change_text(node)
          when Prism::IndexOperatorWriteNode then place_change_text(node, index_text(node))
          when Prism::IndexAndWriteNode, Prism::IndexOrWriteNode then index_logic_write_text(node)
          when Prism::CallOperatorWriteNode then attribute_change_text(node)
          when Prism::ReturnNode, Prism::BreakNode, Prism::NextNode then jump_text(node)
          when *OWN_SCOPES then own_scope_text(node)
          when Prism::ParenthesesNode, Prism::BeginNode then grouped_text(node)
          when Prism::StatementsNode then statements_text(node)
          when Prism::ClassNode, Prism::ModuleNode then module_text(node)
          when Prism::RangeNode then range_text(node)
          when Prism::ArrayNode then node.elements.any?(Prism::SplatNode) ? splat_array_text(node) : copied_text(node)
          when Prism::InterpolatedStringNode then text_with_pieces?(node) ? interpolated_string_text(node) : copied_text(node)
          when Prism::ConstantWriteNode then own_class_write_text(node)
          when Prism::ConstantReadNode then own_class_read?(node) ? own_class_local(node.name) : copied_text(node)
          else copied_text(node)
          end
        end

        # The constants a game block gives a class with fields of its own, `Spark = Struct.new(:x)`
        # (BlockChecks.makes_class?). A block runs once for each build, so a constant would be set
        # again on every build, and two builds at once in Ractors would each set it: each of these
        # is a local of the block instead, read wherever the block names the constant.
        def own_classes_in(node)
          own = node.is_a?(Prism::ConstantWriteNode) && BlockChecks.makes_class?(node.value) ? [node.name] : []
          inner = node.compact_child_nodes.reject { |child| child.is_a?(Prism::DefNode) }
          own.to_set.merge(inner.flat_map { |child| own_classes_in(child).to_a })
        end

        # `low..high` with an end that may be a game number, as `Range.new(low, high)`: making a
        # Range asks its ends `<=>`, which a game number answers only for Range.new (Value#<=>).
        # Ends written out as numbers, or left out, stay as written.
        def range_text(node)
          ends = [node.left, node.right]
          return copied_text(node) if ends.all? { |side| side.nil? || RANGE_ENDS_WRITTEN_OUT.any? { |kind| side.is_a?(kind) } }

          sides = ends.map { |side| side ? argument(side) : "nil" }
          "::Range.new(#{sides.join(', ')}, #{node.exclude_end?})"
        end

        # `"HP #{hp}"`, as the pieces it is made of handed to Steps.text_of, which joins them into
        # Ruby's String, or into words with a number in them where a piece is a number the game
        # works out (DSL::TextWithNumbers). A heredoc stays as written (#embedded_text).
        # Does +node+ put something worked out into the String? Strings written side by side
        # (`"a #{b}" "c"`) hold each as a part.
        def text_with_pieces?(node)
          !heredoc?(node) && node.parts.any? do |part|
            part.is_a?(Prism::EmbeddedStatementsNode) || part.is_a?(Prism::EmbeddedVariableNode) ||
              (part.is_a?(Prism::InterpolatedStringNode) && text_with_pieces?(part))
          end
        end

        def interpolated_string_text(node)
          @in_text += 1
          pieces = node.parts.map do |part|
            case part
            when Prism::StringNode then part.unescaped.inspect
            when Prism::EmbeddedStatementsNode then part.statements ? "(#{rewritten_text(part.statements)})" : '""'
            when Prism::EmbeddedVariableNode then "(#{rewritten_text(part.variable)})"
            else "(#{rewritten_text(part)})"
            end
          end
          text = "#{STEPS}.text_of([#{pieces.join(', ')}])"
          # What follows keeps its line number, however many lines the String took.
          missing = line_ends_between(node.location.start_offset, node.location.end_offset).length - text.count("\n")
          text + ("\n" * [missing, 0].max)
        ensure
          @in_text -= 1
        end

        RANGE_ENDS_WRITTEN_OUT =[Prism::IntegerNode, Prism::FloatNode, Prism::NilNode].freeze

        def own_class_local(name) = "__plain_ruby_class_#{name}"

        # A method cannot see the block's locals, so one keeps the constant as written.
        def own_class_read?(node) = @own_classes.include?(node.name) && !@in_method

        # `Spark = Struct.new(...)` in a game block, as the local of #own_classes_in, its class told
        # the name it was given for the build's messages.
        def own_class_write_text(node)
          return copied_text(node) unless @own_classes.include?(node.name)

          "#{own_class_local(node.name)} = ::VBlank::DSL::PlainRuby::StructSettings.own_class(:#{node.name}, " \
            "(#{rewritten_text(node.value)}))"
        end

        # A `class` or `module` whose code reads or writes an instance variable at an index the game
        # may work out marks it, last in its body, so that an Array of numbers a `game_variables`
        # line names becomes a list (InstanceVariables.keep_arrays_as_lists). The mark is on the
        # class this file opens, so it holds wherever the `game_variables` line is: in this file, in
        # a file brought in before this one, or in a parent the class is made from. A named Array
        # is made a game's at the first line of game code that reads it, as the game is built,
        # which is after every file it is made from has run.
        #
        # The instance variables its code may change as the game plays are marked the same way
        # (InstanceVariables.mark_changing), and for the same reason: each is known before the first
        # line of game code reads one.
        def module_text(node)
          text = copied_text(node)
          return text unless @follows_instance_variables

          lists = @names.instance_variables_at_worked_out_keys_by_module.fetch(node, nil)
          changing = @names.changing_instance_variables_by_module.fetch(node, nil)
          readers = plain_reader_labels(node)
          marks = []
          marks << "#{INSTANCE_VARIABLES}.keep_arrays_as_lists(self, #{lists.to_a.inspect}); " if lists
          marks << "#{INSTANCE_VARIABLES}.mark_changing(self, #{changing.to_a.inspect}); " if changing
          marks << "#{INSTANCE_VARIABLES}.mark_plain_readers(self, #{readers.inspect}); " unless readers.empty?
          return text if marks.empty?

          # Whatever stands before `end` ends the last line with a line break or a `;` already.
          "#{text.delete_suffix('end')}#{marks.join}end"
        end

        # The instance variables the body of +node+ hands out through a reader of the same name
        # that answers just what it holds, as `:@counts`: `attr_reader :counts`, `attr_accessor`, or
        # `def counts = @counts`. A walk's read-ahead may read the instance variable in place of
        # such a reader (InstanceVariables.plain_reader?), never of one that answers a copy.
        def plain_reader_labels(node)
          return [] unless node.body.is_a?(Prism::StatementsNode)

          node.body.body.flat_map do |statement|
            if statement.is_a?(Prism::CallNode) && %i[attr_reader attr_accessor].include?(statement.name) &&
               statement.receiver.nil? && statement.arguments
              statement.arguments.arguments.grep(Prism::SymbolNode).map { |name| :"@#{name.unescaped}" }
            elsif plain_reader_def?(statement)
              [:"@#{statement.name}"]
            else []
            end
          end
        end

        def plain_reader_def?(statement)
          return false unless statement.is_a?(Prism::DefNode) && statement.receiver.nil? && statement.parameters.nil?

          body = statement.body
          body = body.body.first if body.is_a?(Prism::StatementsNode) && body.body.one?
          body.is_a?(Prism::InstanceVariableReadNode) && body.name == :"@#{statement.name}"
        end

        public

        # The game block's own instance variables its code may change as the game plays
        # (LocalNames#changing_instance_variables), as `:@score`. Asked once the block is rewritten.
        def changing_instance_variables = @names.changing_instance_variables.to_a

        # ...and the attributes it may change through a writer (LocalNames#changing_attributes).
        def changing_attributes = @names.changing_attributes.to_a

        private

        # A statement with another after it has nothing reading its value, so a join there
        # needs no variable to keep its answer in.
        def statements_text(node)
          node.body[0...-1].each { |statement| @lone_joins[statement] = true }
          node.body.each { |statement| @whole_statements[statement] = true }
          @open_statements.push([node, @open_tests.length])
          copied_text(node)
        ensure
          @open_statements.pop
        end

        # `( ... )` and `begin ... end` give back their last line, so it is an answer.
        def grouped_text(node)
          note_answer_tail(node.is_a?(Prism::BeginNode) ? node.statements : node.body)
          copied_text(node)
        end

        # +statements+' last line is what they give back, read by whatever holds them.
        def note_answer_tail(statements)
          @answer_tails[statements.body.last] = true if statements.is_a?(Prism::StatementsNode)
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
            statement.location.end_offset <= write.location.start_offset && @promotion.local(statement).plain? &&
            !reads_local?(statement.value, write.name)
        end

        def reads_local?(node, name)
          return true if node.is_a?(Prism::LocalVariableReadNode) && node.name == name

          node.compact_child_nodes.any? { |child| reads_local?(child, name) }
        end

        # The node's text, with what is inside it rewritten. A heredoc's lines sit past the end
        # of the node that opened them, and the text around the node carries them, so they
        # are left out here. +from+ starts the copy further in, the children before it left out.
        IMPLICIT_PARAMETERS = [Prism::ItParametersNode, Prism::NumberedParametersNode].freeze # A block's `it` and `_1`

        def copied_text(node, from: node.location.start_offset)
          at = from
          ends = node.location.end_offset
          # `it` and `_1` give a block an implicit parameters node that spans the whole block, so taken
          # as a child it would copy the body as written: it has no text of its own to copy.
          children = node.compact_child_nodes.reject { |child| IMPLICIT_PARAMETERS.any? { |kind| child.is_a?(kind) } }
          pieces = children.sort_by { |child| child.location.start_offset }.map do |child|
            start = child.location.start_offset
            next "" if start < at || start >= ends

            text = rewritten_text(child)
            text = arguments_followed_text(node, child, text)
            text = "#{INSTANCE_VARIABLES}.making_part(self) do; #{text}; end" if initialize_body?(node, child)
            piece = between(at, start) + text
            at = child.location.end_offset
            piece
          end
          pieces.join + between(at, node.location.end_offset)
        end

        # `[a, *b]`, each spread Array handed to InstanceVariables.refuse_keyed_array_copied! first,
        # which refuses a named Array's game variables being copied into a new one.
        def splat_array_text(node)
          at = node.location.start_offset
          pieces = node.elements.map do |element|
            text = if element.is_a?(Prism::SplatNode) && element.expression
                     "*#{INSTANCE_VARIABLES}.refuse_keyed_array_copied!(#{rewritten_text(element.expression)})"
                   else
                     rewritten_text(element)
                   end
            piece = between(at, element.location.start_offset) + text
            at = element.location.end_offset
            piece
          end
          pieces.join + between(at, node.location.end_offset)
        end

        # Is +child+ the body of +node+, an object's `initialize`? The body runs inside
        # InstanceVariables.making_part, on the line it was written, so a part game code makes is
        # made once (Builder#making_part).
        def initialize_body?(node, child)
          node.is_a?(Prism::DefNode) && node.name == :initialize && node.receiver.nil? && child.equal?(node.body)
        end

        # +text+, the body +child+ of +node+, a method or a block of game code, first following the
        # objects its parameters hold (InstanceVariables.follow_objects_in): an object a plain file
        # made, handed to a method or yielded to a block, is first named there. A body with `rescue`
        # is left as it is, since it cannot be put in parentheses. A block that reads its argument
        # as `it` or `_1` cannot be given a copy back, so a Data object that needs one there is
        # refused (InstanceVariables.follow_unnamed_parameters).
        def arguments_followed_text(node, child, text)
          return text unless @follows_instance_variables && PARAMETERS_FOLLOWED.any? { |kind| node.is_a?(kind) }
          return text unless child.equal?(node.body)
          return text if child.is_a?(Prism::BeginNode)

          names = case node
                  when Prism::DefNode then parameter_names(node.parameters)
                  when Prism::BlockNode then block_parameter_names(node.parameters)
                  else []
                  end
          unnamed = node.is_a?(Prism::BlockNode) ? unnamed_parameter_names(node.parameters) : []
          return "(#{INSTANCE_VARIABLES}.follow_unnamed_parameters([#{unnamed.join(', ')}]); #{text}\n)" if unnamed.any?
          return text if names.empty?

          listed = names.join(", ")
          "(#{listed}, = #{INSTANCE_VARIABLES}.follow_objects_in([#{listed}]); #{text}\n)"
        end

        # `it`, or `_1` up to the highest a block reads.
        def unnamed_parameter_names(parameters)
          case parameters
          when Prism::ItParametersNode then ["it"]
          when Prism::NumberedParametersNode then (1..parameters.maximum).map { |at| "_#{at}" }
          else []
          end
        end

        def parameter_names(parameters)
          return [] unless parameters

          named = [*parameters.requireds, *parameters.optionals, parameters.rest, *parameters.posts, *parameters.keywords,
                   parameters.keyword_rest]
          named.filter_map { |parameter| parameter.name if parameter.respond_to?(:name) && parameter.name }
        end

        PARAMETERS_FOLLOWED = [Prism::DefNode, Prism::BlockNode].freeze # Whose parameters #arguments_followed_text follows

        # The names a block's `|...|` gives; none for `it` or `_1`, which have no list.
        def block_parameter_names(parameters)
          parameters.is_a?(Prism::BlockParametersNode) ? parameter_names(parameters.parameters) : []
        end

        # A `return` in a block belongs to that block, so tests open outside it do not apply.
        #
        # A block inside `initialize` (a routine's body, say) is game code, not the object's start.
        def own_scope_text(node)
          outer = @open_tests
          outer_block_tests = @block_tests
          outer_statements = @open_statements
          outer_initialize = @in_initialize
          outer_method = @in_method
          outer_targets = @jump_targets
          @block_tests = node.is_a?(Prism::DefNode) ? [] : @block_tests + outer
          @open_tests = []
          @open_statements = []
          target = @jump_target_blocks.delete(node)
          @jump_targets = target ? [[target, 0]] : []
          @in_initialize = node.is_a?(Prism::DefNode) && node.name == :initialize && node.receiver.nil?
          @in_method ||= node.is_a?(Prism::DefNode)
          @tail_ternaries[node.body.body.last] = true if method_body?(node)
          note_answer_tail(node.body) if node.is_a?(Prism::DefNode)
          copied_text(node)
        ensure
          @open_tests = outer
          @block_tests = outer_block_tests
          @open_statements = outer_statements
          @in_initialize = outer_initialize
          @in_method = outer_method
          @jump_targets = outer_targets
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
        #
        # A `break` or `next` in a loop's own body asks the loop (Jumps#jump!), handing it the tests
        # open inside the loop: a loop the game runs records the jump, and one Ruby runs while
        # building lets Ruby make it, as long as none of those tests is the game's.
        def jump_text(node)
          target = @jump_targets.last
          return loop_jump_text(node, *target) if target && !node.is_a?(Prism::ReturnNode)
          return copied_text(node) if @open_tests.empty?

          refusals = @open_tests.map { |test| "#{test}.refuse_jump!(:#{jump_word(node)})" }.join("; ")
          "(#{refusals}; if true then #{copied_text(node)} end)"
        end

        def loop_jump_text(node, loop, depth)
          tests = "[#{@open_tests[depth..].join(', ')}]"
          if loop == DO_WHILE_TARGET
            return "(#{STEPS}.refuse_jump_in_do_while!(:#{jump_word(node)}, #{tests}); if true then #{copied_text(node)} end)"
          end

          value = node.arguments ? ", with_value: true" : ""
          "(if #{loop}.jump!(:#{jump_word(node)}, #{tests}#{value}) then #{copied_text(node)} end)"
        end

        # A reader call whose answer is indexed (`keeper.counts` in `keeper.counts[at] += 1`) hands
        # the Array it really answers to InstanceVariables.indexed, which decides from that Array
        # and the object whose instance variable holds it, never from the reader's name.
        def call_text(node)
          site = @names.reader_index_sites[node] if @follows_instance_variables
          note_values_read_at_once(node)
          text = call_text_as_written(node)
          text = values_handed_text(text) if values_handed?(node)
          return text unless site

          "#{INSTANCE_VARIABLES}.indexed((#{text}), worked_out: #{site.worked_out}, changed: #{site.changed})"
        end

        # `h.values` and the other calls that hand back an Array of a Hash's values
        # (InstanceVariables::KeyedHash::VALUES_HANDED). On a Hash of game variables the Array holds
        # those variables, where Ruby's holds the numbers of that moment, so the answer is checked
        # as the line runs (InstanceVariables.refuse_hash_values_handed!). A call that only reads the
        # answer straight away, `h.values.sum` (#note_values_read_at_once), is left as written.
        def values_handed?(node)
          node.receiver && InstanceVariables::KeyedHash::VALUES_HANDED.include?(node.name) &&
            !values_read_at_once.key?(node)
        end

        def values_handed_text(text) = "#{INSTANCE_VARIABLES}.refuse_hash_values_handed!(#{text})"

        # +node+ reads what its receiver hands back and keeps none of it (`h.values.sum`,
        # `h.values.each { ... }`): the receiver's answer is never kept, so it is no copy.
        def note_values_read_at_once(node)
          receiver = node.receiver
          return unless receiver.is_a?(Prism::CallNode) && read_at_once?(node.name)

          values_read_at_once[receiver] = true
        end

        # Does +name+ read an Array's items and answer a number, a test or nothing: a question
        # ItemQuestions answers, or a walk?
        def read_at_once?(name) = ItemQuestions::QUESTIONS.include?(name) || READ_AT_ONCE.include?(name)

        READ_AT_ONCE = %i[sum size length empty? each each_with_index].freeze

        def values_read_at_once = (@values_read_at_once ||= {}.compare_by_identity)

        def call_text_as_written(node)
          note_tail_of_answering_block(node)
          return "#{STEPS}.opposite(#{argument(node.receiver)})" if node.name == :! && node.receiver
          return "#{ARRAYS}.taken(#{argument(node.receiver)}, :#{node.name})" if game_array_item_taken?(node)
          return index_write_text(node) if node.name == :[]= && node.receiver
          return whole_array_change_text(node) if whole_array_change?(node)
          return own_array_change_text(node) if own_array_change?(node)
          return attribute_write_text(node) if node.attribute_write? && node.receiver
          return "#{STEPS}.nil_test(#{argument(node.receiver)})" if node.name == :nil? && node.receiver
          return nil_comparison_text(node) if LocalNames.nil_comparison?(node)
          return equality_text(node) if equality?(node)
          return bits_text(node) if Steps::BIT_JOINS.include?(node.name) && node.receiver && node.arguments
          return "self.#{copied_text(node)}" if node.receiver.nil? && @outer_locals.include?(node.name)
          return game_variables_text(node) if game_variables_call?(node)
          return "#{ARRAYS}.ruby_array#{copied_text(node, from: node.message_loc.end_offset)}" if ruby_array_with_room?(node)
          return item_question_text(node) if item_question?(node)
          return kind_question_text(node) if kind_question?(node)
          return case_equality_text(node) if case_equality?(node)
          return "#{STEPS}.class_of(#{argument(node.receiver)})" if class_asked?(node)
          if node.name == :<=> && node.receiver && node.arguments
            return "#{STEPS}.compare(#{argument(node.receiver)}, #{rewritten_text(node.arguments)})"
          end
          return "#{INSTANCE_VARIABLES}.followed_struct(#{copied_text(node)})" if struct_made?(node)
          if @follows_instance_variables && @whole_statements.key?(node)
            return attribute_methods_text(node) if attribute_call?(node)
            return visible_attribute_methods_text(node) if visibility_of_attribute_call?(node)
          end
          return listed_attribute_methods_text(node) if listed_attribute_call?(node)
          return counted_loop_text(node) if node.receiver && node.block.is_a?(Prism::BlockNode)
          return endless_loop_text(node) if endless_loop?(node)

          copied_text(node)
        end

        # The numbers Ruby counts with given a block, `n.times { }`, `0.upto(n) { }` or
        # `(0...n).each { }`, answered by Counts: Ruby's own on plain numbers, a loop the game runs
        # where either end is a number the game keeps.
        #
        # A `break` or `next` in the block is the loop's (#jump_text), as Ruby's is: the block is
        # the loop's body, handed the loop's Jumps.
        def counted_loop_text(node)
          range = range_written(node.receiver)
          return copied_text(node) unless range || COUNTING_LOOPS.include?(node.name)

          made = block_jumps_text(node)
          start =
            if range
              from = range.left ? argument(range.left) : "nil"
              upto = range.right ? argument(range.right) : "nil"
              "#{COUNTS}.range(#{from}, #{upto}, #{range.exclude_end?}#{made})"
            else
              "#{COUNTS}.start(#{argument(node.receiver)}#{made})"
            end
          start + copied_text(node, from: node.receiver.location.end_offset)
        end

        # `loop do ... end` with a `break` in it, which Counts.endless makes a loop the game runs
        # in game code.
        def endless_loop?(node)
          node.receiver.nil? && node.name == :loop && node.arguments.nil? && node.block.is_a?(Prism::BlockNode) &&
            jump_words(node.block.body).include?(:break)
        end

        def endless_loop_text(node)
          "#{COUNTS}.endless(#{block_jumps_text(node).delete_prefix(', ')})" +
            copied_text(node, from: node.message_loc.end_offset)
        end

        # `, __plain_ruby_7 = Jumps.new([:break])` for a call whose block holds a `break` or a
        # `next`, the block marked as that loop's body; "" for one with neither.
        def block_jumps_text(node)
          jumps = jumps_text(node.block.body)
          return "" unless jumps

          target = fresh_name
          @jump_target_blocks[node.block] = target
          ", #{target} = #{jumps}"
        end

        # `a..b` or `(a...b)` written as it is.
        def range_written(node)
          node = node.body.body.first while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) &&
                                                node.body.body.length == 1
          node if node.is_a?(Prism::RangeNode)
        end

        # `item = trail.shift` on a game's own list, where something reads the item it drops: a
        # line it is part of, or a branch or method whose answer it is. Standing alone, the drop
        # needs nothing kept.
        def game_array_item_taken?(node)
          %i[shift pop].include?(node.name) && node.arguments.nil? && node.block.nil? &&
            node.receiver.is_a?(Prism::LocalVariableReadNode) && @names.game_array?(node.receiver) &&
            !value_unused?(node)
        end

        # `game_variables :busy`, which no object answers: InstanceVariables keeps the names.
        def game_variables_call?(node)
          @follows_instance_variables && node.name == :game_variables && node.receiver.nil? && node.block.nil?
        end

        # `flock.dots << dot` or `part.counts.rotate!`: an Array verb that changes the answer of a
        # reader call as a whole. InstanceVariables.refuse_changed_from_outside! is handed the
        # answer first, and refuses a part's Array its class does not change. A slot written
        # (`part.counts[i] = 1`) is the index rewrite's. VBlank's own files are left as they are.
        def whole_array_change?(node)
          @follows_instance_variables && !node.receiver.nil? && node.name != :[]= &&
            Arrays::CHANGING_VERBS.include?(node.name) && reader_call?(node.receiver)
        end

        # A call with a receiver, no arguments and no block, named as a reader is: `flock.dots`.
        def reader_call?(node)
          node.is_a?(Prism::CallNode) && !node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
            node.name.match?(/\A[a-z_]\w*\z/)
        end

        # `@dots << dot`, `@scores.shift`: an instance variable's Array changed as a whole by a line
        # of its own class, which InstanceVariables.refuse_unkept_change! holds to what the game
        # keeps. VBlank's own files are left as they are.
        def own_array_change?(node)
          @follows_instance_variables && node.name != :[]= && Arrays::CHANGING_VERBS.include?(node.name) &&
            node.receiver.is_a?(Prism::InstanceVariableReadNode)
        end

        def own_array_change_text(node)
          "#{INSTANCE_VARIABLES}.refuse_unkept_change!(#{argument(node.receiver)}, :#{node.name}, :#{node.receiver.name})" \
            "#{copied_text(node, from: node.receiver.location.end_offset)}"
        end

        def whole_array_change_text(node)
          "#{INSTANCE_VARIABLES}.refuse_changed_from_outside!(#{argument(node.receiver)}, :#{node.name})" \
            "#{copied_text(node, from: node.receiver.location.end_offset)}"
        end

        # `[a, b].max`, `scores.count { |n| n > 5 }`: a question about the items of whatever the
        # receiver turns out to be, which ItemQuestions answers as Ruby would, or works out as the
        # game plays where Ruby could not. VBlank's own files are left as they are.
        def item_question?(node)
          @follows_instance_variables && !node.receiver.nil? && ItemQuestions::VERBS.include?(node.name) &&
            !node.safe_navigation?
        end

        def item_question_text(node)
          given = node.arguments ? ", #{rewritten_text(node.arguments)}" : ""
          given += ", #{rewritten_text(node.block)}" if node.block.is_a?(Prism::BlockArgumentNode)
          block = node.block.is_a?(Prism::BlockNode) ? " #{rewritten_text(node.block)}" : ""
          "::VBlank::DSL::PlainRuby::ItemQuestions.ask(#{argument(node.receiver)}, :#{node.name}#{given})#{block}"
        end

        # `trail.is_a?(Array)`: what kind the receiver is, which Steps.kind_question answers as
        # Ruby would for an Array the game keeps. VBlank's own files are left as they are.
        def kind_question?(node)
          @follows_instance_variables && !node.receiver.nil? && KIND_QUESTIONS.include?(node.name) &&
            node.arguments&.arguments&.length == 1 && node.block.nil? && !node.safe_navigation?
        end

        KIND_QUESTIONS = %i[is_a? kind_of? instance_of?].freeze

        def kind_question_text(node)
          "#{STEPS}.kind_question(#{argument(node.receiver)}, :#{node.name}, #{rewritten_text(node.arguments)})"
        end

        # `Array === trail`, a constant asking: Steps.case_equality answers it as #kind_question? does.
        def case_equality?(node)
          @follows_instance_variables && node.name == :=== && CONSTANT_RECEIVERS.any? { |kind| node.receiver.is_a?(kind) } &&
            node.arguments&.arguments&.length == 1 && node.block.nil?
        end

        CONSTANT_RECEIVERS = [Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

        def case_equality_text(node)
          "#{STEPS}.case_equality(#{rewritten_text(node.receiver)}, #{rewritten_text(node.arguments)})"
        end

        # `trail.class`, which Steps.class_of answers Array for an Array the game keeps.
        def class_asked?(node)
          @follows_instance_variables && node.name == :class && !node.receiver.nil? && node.arguments.nil? &&
            node.block.nil? && !node.safe_navigation?
        end

        # `Array.new(capacity: 4)` that game code never changes, so it stays Ruby's (a game's own is
        # made by #game_array_text before this is reached). Ruby's `Array.new` takes no settings.
        def ruby_array_with_room?(node)
          Arrays.makes_array?(node) && node.arguments&.arguments.to_a.any?(Prism::KeywordHashNode)
        end

        # `Struct.new(:count)`, whose named fields InstanceVariables follows as it follows named
        # instance variables, or `Data.define(:x)`, whose reads it notes (InstanceVariables.followed_struct).
        def struct_made?(node)
          return false unless @follows_instance_variables

          made = { new: :Struct, define: :Data }[node.name]
          receiver = node.receiver
          return false unless made

          (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == made) ||
            (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil? && receiver.name == made)
        end

        # In a method, `def self.setup` above all, it would run on whatever the method runs on, and
        # name nothing a game reads, so it is refused there. The arguments are passed as written,
        # so `saved: false` arrives as a keyword and a name given as `states: :lit_state` among the
        # rest.
        #
        # In the game block, outside any class, the line also marks the instance variables the
        # block reads at an index the game may work out, which are the builder's own. A class's
        # are marked by the class (#module_text).
        def game_variables_text(node)
          return "#{INSTANCE_VARIABLES}.refuse_named_in_method!" if @in_method

          names = node.arguments ? ", #{rewritten_text(node.arguments)}" : ""
          naming = "#{INSTANCE_VARIABLES}.name_game_variables(self#{names})"
          lists = labels_named_by(node) & @names.instance_variables_at_worked_out_keys.to_a
          return naming if lists.empty?

          "(#{naming}; #{INSTANCE_VARIABLES}.keep_arrays_as_lists(self, #{lists.inspect}))"
        end

        # The instance variables a `game_variables` line names, as `:@counts`: each symbol, and
        # each key of a name given one of its own (`states: :lit_state`).
        def labels_named_by(node)
          node.arguments&.arguments.to_a.flat_map do |argument|
            case argument
            when Prism::SymbolNode then [argument.unescaped.to_sym]
            when Prism::KeywordHashNode, Prism::HashNode
              argument.elements.grep(Prism::AssocNode).map(&:key).grep(Prism::SymbolNode).map { |key| key.unescaped.to_sym }
            else []
            end
          end.map { |name| :"@#{name}" }
        end

        # What each of Ruby's attribute calls makes: a reader, a writer, or both.
        ATTRIBUTE_METHODS_MADE = Ractor.make_shareable({ attr_reader: %i[reader], attr_writer: %i[writer],
                                                         attr_accessor: %i[reader writer] })

        VISIBILITY_CALLS = %i[private protected public].freeze # What `private attr_reader :busy` can start with

        # `attr_reader :busy`, `attr_writer` or `attr_accessor`, on a line of its own. The methods
        # Ruby makes reach the instance variable without this rewrite, so another part testing
        # `tilt.busy` in game code would ask the number it was set up with, and `tilt.busy = 1`
        # would change it unseen. So each is written out as a method that reads or writes it as a
        # line here does, on the same line.
        def attribute_call?(node)
          ATTRIBUTE_METHODS_MADE.key?(node.name) && node.receiver.nil? && node.block.nil? &&
            node.arguments&.arguments&.all?(Prism::SymbolNode) && !node.arguments.arguments.empty?
        end

        def attribute_methods_text(node)
          made = ATTRIBUTE_METHODS_MADE.fetch(node.name)
          methods = node.arguments.arguments.flat_map { |name| made.map { |kind| attribute_method_text(kind, name.unescaped) } }
          methods.join("; ") + line_ends_between(node.location.start_offset, node.location.end_offset)
        end

        def attribute_method_text(kind, name)
          place = :"@#{name}"
          return "def #{name} = #{instance_variable_read_call(place)}" if kind == :reader

          given = "__plain_ruby_written"
          write = write_call(instance_variable_place_text(place), given, place, options: ", moves: true, owner: self")
          "def #{name}=(#{given}); #{place} = #{write}; end"
        end

        # `attr_accessor(*LEVELS)`, or any call whose names are not written out as symbols, which no
        # source can be written for: InstanceVariables.attribute_methods makes the same methods as
        # the class's body runs, and answers their names, as Ruby's call does.
        def listed_attribute_call?(node)
          @follows_instance_variables && ATTRIBUTE_METHODS_MADE.key?(node.name) && node.receiver.nil? &&
            node.block.nil? && node.arguments && !attribute_call?(node)
        end

        def listed_attribute_methods_text(node)
          "#{INSTANCE_VARIABLES}.attribute_methods(self, :#{node.name}, [#{rewritten_text(node.arguments)}])"
        end

        # `private attr_reader :busy`.
        def visibility_of_attribute_call?(node)
          VISIBILITY_CALLS.include?(node.name) && node.receiver.nil? && node.block.nil? &&
            node.arguments&.arguments&.one? && node.arguments.arguments.first.is_a?(Prism::CallNode) &&
            attribute_call?(node.arguments.arguments.first)
        end

        # The methods written out, then each given the visibility the call asked for.
        def visible_attribute_methods_text(node)
          made = node.arguments.arguments.first
          names = made.arguments.arguments.map(&:unescaped)
          methods = ATTRIBUTE_METHODS_MADE.fetch(made.name).flat_map do |kind|
            names.map { |name| kind == :reader ? name : "#{name}=" }
          end
          "#{attribute_methods_text(made)}; #{node.name} #{methods.map { |name| name.to_sym.inspect }.join(', ')}"
        end

        # A verb that reads a number off its block's last line takes a ternary there as the
        # number, as a method's answer does. Any other block's last line is left as a statement,
        # since nothing reads it and keeping its value would add to the cartridge.
        def note_tail_of_answering_block(node)
          return unless ANSWERING_BLOCK_VERBS.include?(node.name) && node.block.is_a?(Prism::BlockNode)

          body = node.block.body
          note_answer_tail(body)
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

        # `slots[i] = value`. The value is written for its value, so a ternary, an `if` with an
        # `else` or a `case` there picks the number that goes into the slot, as it does into
        # `x = ...`; as a statement it would record its two sides and hand on nothing.
        def index_write_text(node)
          *keys, value = node.arguments.arguments
          keys = keys.map { |key| argument(key) }
          slot_write_text(argument(node.receiver), keys, "(#{value_text(value)})", written_place(node, node.arguments))
        end

        # ...and `thing.field = value`, the same way.
        def attribute_write_text(node)
          label = node.slice[/\A[^=]*/].strip
          value = "(#{value_text(node.arguments.arguments.first)})"
          attribute_write(argument(node.receiver), node.name.to_s.delete_suffix("="), value, label)
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

        # `counts[0] &&= value` and `||=`: Ruby's own, with the receiver and keys worked out once,
        # after Writes.refuse_logic_slot_write! has looked at what the slot holds (a number the game
        # keeps cannot take part).
        def index_logic_write_text(node)
          holder = fresh_name
          held_keys = fresh_name
          keys = node.arguments ? node.arguments.arguments.map { |key| argument(key) } : []
          label = "#{node.receiver.slice}[#{node.arguments&.arguments.to_a.map(&:slice).join(', ')}]"
          "(#{holder} = #{argument(node.receiver)}; #{held_keys} = [#{keys.join(', ')}]; " \
            "#{WRITES}.refuse_logic_slot_write!(#{holder}[*#{held_keys}], #{label.inspect}, #{node.operator.inspect}); " \
            "#{holder}[*#{held_keys}] #{node.operator} #{argument(node.value)})"
        end

        # `+=` on a place. The block is what Ruby would do, for a place that holds no variable.
        # +field+ is the text naming the object and the attribute of `point.x += 1`, for Writes.change.
        def place_change_text(node, place, field: nil)
          label = between(node.location.start_offset, node.binary_operator_loc.start_offset).strip
          field_option = field ? ", field: #{field}" : ""
          "#{WRITES}.change(#{place}, :#{node.binary_operator}, #{argument(node.value)}, #{open_tests_text}, " \
            "#{label.to_sym.inspect}#{field_option}) { |#{NEW_VALUE}| #{place} = #{NEW_VALUE} }"
        end

        # `point.x += 1`: the receiver is held, so what it is worked out from runs once.
        def attribute_change_text(node)
          holder = fresh_name
          "(#{holder} = #{rewritten_text(node.receiver)}; " \
            "#{place_change_text(node, "#{holder}.#{node.read_name}", field: "[#{holder}, :#{node.read_name}]")})"
        end

        # A plain number changed from inside a block no one can place: `each` may be Ruby's, which
        # runs now, or a pool's, which records game code. Only running it can tell, so the step
        # looks, using the question the block's builder answers.
        #
        # A name of the scope around a block, changed in it under a test the game makes, was given a
        # variable before the test if anything reads it after (Promotion#before_test), and the
        # write goes to that under the tests open around the block. One nothing reads after is
        # Ruby's, since only code on that side reads it.
        #
        # A number changed from a block that may be a pool's `each` (Promotion#local's
        # :changed_from_unplaced_block) is decided as each line runs (Promotion.unplaced_change).
        # While the line records game code, the name is a game variable: its first line sets it there, so a method called on every pass starts it
        # afresh, and a change from the block makes it one holding the number it has then. While
        # setting up it stays Ruby's, so `names.each { count += 1 }` over a Ruby list counts in Ruby.
        #
        # That number is decided before a promotion is: the name may be the game variable its own
        # line made by now, and a promoted write under a test decided while building would only
        # give the name a working-out of it, so a pool's `each` would add once whatever it holds.
        def guarded_write_text(node, written)
          return unknown_block_write_text(node) if @promotion.local(node).decided_while_running?
          return under_open_tests(@block_tests) { write_or_change_text(node) } if promoted_in_block?(node)

          written
        end

        # A read of a number changed from a block only running can place, made from inside such a
        # block. A method made from a block may test the name before it changes it (`x += 1 if
        # shown == 0; shown = x`), so while game code is recorded the read makes it the game
        # variable too, or the test would be decided once, while building, from the number it held.
        def unknown_block_read_text(node)
          return copied_text(node) unless @promotion.local(node).decided_while_running?

          "(#{variable_while_recording_text(node)})"
        end

        def unknown_block_write_text(node)
          if @names.first_write?(node)
            prefix = between(node.location.start_offset, node.value.location.start_offset)
            return "#{prefix}#{WRITES}.start_variable_while_recording(self, (#{value_text(node.value)}), " \
                   ":#{@names.variable_name_of(node)}, #{RECORDING_TEST_SOURCE}#{source_option_text}" \
                   "#{walked_option_text(node)})"
          end

          tests = promoted_in_block?(node) ? @block_tests : []
          options = walk_unread?(node) ? ", walk_unread: true" : ""
          written = under_open_tests(tests) { variable_write_text(node, options) }
          "(#{variable_while_recording_text(node)}; #{written})"
        end

        # What the blocks that change the name +node+ starts are called on, read where it starts
        # (Writes.start_variable_while_recording's +walked+): in a part's method, which runs on no
        # builder, a walk over an Array the game keeps is what makes the name the game's. Each is
        # read before the block runs where that has no other effect (#receiver_read_ahead_text).
        def walked_option_text(node)
          read = @names.unplaced_receivers(node).filter_map { |receiver| receiver_read_ahead_text(receiver) }.uniq
          return "" if read.empty?

          ", walked: -> { [#{read.join(', ')}] }"
        end

        # The Ruby that reads +receiver+, what a block is called on, before the block runs, or nil
        # where it cannot be read ahead (#walk_unread?). An instance variable, a constant or a
        # literal reads as itself. A local reads where it is set by then, and nil where it is not
        # yet. A bare name with no arguments is the part's reader where its class hands the instance
        # variable of that name out as it is (InstanceVariables.plain_reader?), read straight from
        # it, so the reader is not called twice.
        def receiver_read_ahead_text(receiver)
          case receiver
          when Prism::InstanceVariableReadNode, Prism::ConstantReadNode, Prism::ConstantPathNode,
               Prism::IntegerNode, Prism::RangeNode, Prism::ArrayNode
            receiver.slice
          when Prism::LocalVariableReadNode
            "(defined?(#{receiver.name}) == \"local-variable\" ? #{receiver.name} : nil)"
          when Prism::CallNode
            return nil unless receiver.receiver.nil? && receiver.arguments.nil? && receiver.block.nil? &&
                              receiver.name.match?(/\A[a-z_]\w*\z/)

            "(#{INSTANCE_VARIABLES}.plain_reader?(self, :#{receiver.name}) ? @#{receiver.name} : nil)"
          end
        end

        # Is a block that changes the name +node+ writes called on something #receiver_read_ahead_text
        # cannot read: a lambda handed with `&`, a helper that yields, a reader with arguments? Its
        # change by a game number is then refused (Writes.refuse_unfollowed_walk!).
        def walk_unread?(node) = @names.unplaced_receivers(node).any? { |receiver| receiver_read_ahead_text(receiver).nil? }

        # The name made the game variable it is to be, if game code is being recorded as this runs.
        def variable_while_recording_text(node)
          "#{node.name} = #{WRITES}.variable_while_recording(self, #{node.name}, :#{@names.variable_name_of(node)}, " \
            "#{RECORDING_TEST_SOURCE}#{source_option_text})"
        end

        # The Ruby a rewritten line asks with: true where the line runs on the builder of the game
        # being built, recording game code (Builder::Session.records_for?). A part of a game runs
        # on no builder, so it answers false there.
        RECORDING_TEST_SOURCE = "::VBlank::Builder::Session.records_for?(self)"

        def promoted_in_block?(node)
          !@block_tests.empty? && node.depth.positive? && @promotion.write_under_test(node).promoted?
        end

        def write_or_change_text(node) = node.is_a?(Prism::LocalVariableOperatorWriteNode) ? change_text(node) : write_text(node)

        # The write of a name that may hold a game variable by now: Writes changes the variable if
        # it does, and leaves the write to Ruby if not. +options+ go to a change (Writes.change).
        def variable_write_text(node, options = "")
          return "#{node.name} = #{change_call(node, options)}" if node.is_a?(Prism::LocalVariableOperatorWriteNode)

          "#{node.name} = #{assign_text(node.name, "(#{value_text(node.value)})")}"
        end

        # A part of a game keeps its variables in these, so one holding a game variable is changed.
        def instance_variable_write_text(node)
          prefix = between(node.location.start_offset, node.value.location.start_offset)
          value = things_array_text(node) || value_text(node.value)
          return "#{prefix}#{WRITES}.keep_as_own((#{value}), self, :#{node.name})" if LocalNames.makes_variable?(node.value)

          copies = @names.moved_in_game_code?(node.name) ? ", copies: true" : ""
          copies += ", shares: true" if @names.argument_read?(node.value)
          "#{prefix}#{write_call(instance_variable_place_text(node.name), "(#{value})", node.name,
                                 options: ", moves: true#{copies}#{owner_option}")}"
        end

        # `@x ||= var :x, 0`, the same as `@x = var :x, 0` the first time.
        def instance_variable_or_text(node)
          return kept_part_text(node, "self") if @follows_instance_variables && part_made?(node.value)
          return instance_variable_logic_text(node, "join_either") unless LocalNames.makes_variable?(node.value)

          "#{node.name} ||= #{WRITES}.keep_as_own((#{value_text(node.value)}), self, :#{node.name})"
        end

        def part_made?(value) = value.is_a?(Prism::CallNode) && value.name == :new

        # `@counter ||= Counter.new`: made the first time the line runs and kept after, as Ruby does,
        # so a part with changing numbers may be made so in game code (InstanceVariables.keeping_part).
        # +owner+ is the text of the object keeping it, `nil` for a local (#kept_local?). Every pass
        # of the line is noted first, the ones Ruby skips too (InstanceVariables.note_kept_part).
        def kept_part_text(node, owner)
          "(#{INSTANCE_VARIABLES}.note_kept_part(#{owner}, :#{node.name}, #{node.value.slice.inspect}); " \
            "#{node.name} ||= #{INSTANCE_VARIABLES}.keeping_part(#{owner}) { #{rewritten_text(node.value)} })"
        end

        # `c ||= Counter.new` in a block of the game's, where `c` is a local of the game's own block,
        # given nothing in any other block: the block of the game runs once, as it is set up, so
        # `c` keeps one part in Ruby across every pass, as the game does. A local of the block
        # running every frame, or one another block sets, is new or changed on a pass, and is left to
        # the refusal of a changing part made every pass.
        def kept_local?(node)
          return false unless @follows_instance_variables && @block_node && part_made?(node.value)
          return false unless node.depth.positive? && scopes_around(@block_node, node)[-1 - node.depth].equal?(@block_node)

          local_writes_in(@block_node, node.name).none? { |write| !write.equal?(node) && write.depth.positive? }
        end

        # The blocks, lambdas and methods under +root+ (itself one) that hold +node+, the innermost last.
        def scopes_around(root, node)
          scopes = []
          at = root
          while at
            scopes << at if OWN_SCOPES.any? { |kind| at.is_a?(kind) }
            at = at.compact_child_nodes.find { |child| holds?(child, node) && !child.equal?(node) }
          end
          scopes
        end

        def holds?(outer, inner)
          outer.location.start_offset <= inner.location.start_offset && inner.location.end_offset <= outer.location.end_offset
        end

        LOCAL_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                        Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode].freeze

        # Every write under +node+ of a local named +name+.
        def local_writes_in(node, name)
          own = LOCAL_WRITES.any? { |kind| node.is_a?(kind) } && node.name == name ? [node] : []
          own + node.compact_child_nodes.flat_map { |child| local_writes_in(child, name) }
        end

        # `@x ||= value` and `@x &&= value`. On an instance variable the game names, in game code,
        # it is `@x = @x || value`, so a yes or no is set as the game plays. Anything else is Ruby's
        # own, which leaves the instance variable alone where it holds something already.
        def instance_variable_logic_text(node, step)
          plain = copied_text(node)
          return plain unless @follows_instance_variables

          joined = "#{STEPS}.#{step}(#{instance_variable_read_call(node.name)}) { #{rewritten_text(node.value)} }"
          current = instance_variable_place_text(node.name)
          followed = "#{node.name} = #{write_call(current, joined, node.name, options: ", moves: true#{owner_option}")}"
          "(#{INSTANCE_VARIABLES}.followed?(self, #{node.name}, :#{node.name}) ? (#{followed}) : (#{plain}))"
        end

        # A read of an instance variable. InstanceVariables follows one the game names, and notes
        # any other read in game code; one in a String or a Symbol is Ruby's by nature.
        def instance_variable_read_text(node)
          return copied_text(node) unless @follows_instance_variables

          instance_variable_read_call(node.name, in_text: @in_text.positive?, read: node)
        end

        # What a line writing an instance variable hands Writes as what it holds
        # (InstanceVariables.value_before_write).
        def instance_variable_place_text(name)
          return name.to_s unless @follows_instance_variables

          instance_variables_call("value_before_write", name)
        end

        # +read+ is the read's own node, where a call on what it holds is checked for nothing held
        # (#nil_failing_reads).
        def instance_variable_read_call(name, in_text: false, read: nil)
          options = in_text ? ", in_text: true" : ""
          options += ", set_in_routine: true" if read && @nil_failing_reads.key?(read) && @set_in_routines.include?(name)
          instance_variables_call("read_value", name, options)
        end

        # The calls that read or write through what they are called on.
        CALLS_ON_RECEIVER = [Prism::CallNode, Prism::CallOperatorWriteNode, Prism::CallOrWriteNode,
                             Prism::CallAndWriteNode].freeze

        # The instance variable reads under +node+ that a method is called on which nil does not answer
        # (`@point.x`, `@point.x += 1`): holding nothing, such a line stops with Ruby's own error.
        def nil_failing_reads(node, found = {}.compare_by_identity)
          if CALLS_ON_RECEIVER.any? { |kind| node.is_a?(kind) } && node.receiver.is_a?(Prism::InstanceVariableReadNode) &&
             node.call_operator != "&." && !nil.respond_to?(node.is_a?(Prism::CallNode) ? node.name : node.read_name)
            found[node.receiver] = true
          end
          node.compact_child_nodes.each { |child| nil_failing_reads(child, found) }
          found
        end

        # The verbs whose block VBlank builds after the game loop, as a routine of its own.
        LATER_BUILT_VERBS = %i[func scene].freeze

        # The instance variables of a game block that a `func` or a scene written in it gives a
        # value (InstanceVariables.refuse_nil_set_in_routine!). None in a game file's classes, whose
        # instance variables are their objects'.
        def instance_variables_set_in_routines(node, inside: false)
          return Set.new unless @block_node
          return Set.new if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          inside ||= node.is_a?(Prism::CallNode) && node.receiver.nil? && LATER_BUILT_VERBS.include?(node.name) &&
                     node.block.is_a?(Prism::BlockNode)
          own = inside && INSTANCE_VARIABLE_WRITES.any? { |kind| node.is_a?(kind) } ? Set[node.name] : Set.new
          node.compact_child_nodes.reduce(own) { |names, child| names | instance_variables_set_in_routines(child, inside: inside) }
        end

        INSTANCE_VARIABLE_WRITES = [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
                                    Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableAndWriteNode,
                                    Prism::InstanceVariableTargetNode].freeze

        # A call to +step+ of InstanceVariables, with a block that keeps the game variable it makes.
        def instance_variables_call(step, name, options = "")
          given = "__plain_ruby_given"
          "#{INSTANCE_VARIABLES}.#{step}(self, #{name}, :#{name}#{options}) { |#{given}| #{name} = #{given} }"
        end

        # `defined?(@x)` asks Ruby about the name itself, so it is left as written.
        def defined_text(node)
          return copied_text(node) unless node.value.is_a?(Prism::InstanceVariableReadNode)

          source_between(node.location.start_offset, node.location.end_offset)
        end

        # The object a game's instance variable belongs to, for Writes (InstanceVariables), and
        # whether the line is one of its `initialize`, which starts it rather than changing it.
        def owner_option
          return "" unless @follows_instance_variables

          @in_initialize ? ", owner: self, starting: true" : ", owner: self"
        end

        def write_text(node)
          prefix = between(node.location.start_offset, node.value.location.start_offset)
          return "#{prefix}#{game_array_text(node)}" if @names.game_array?(node)
          if @names.game_hash?(node)
            return "#{prefix}#{WRITES}.game_hash(self, :#{@names.variable_name_of(node)}, #{rewritten_text(node.value)}" \
                   "#{source_option_text})"
          end
          # A name kept for a read past its `if` can stay a plain name under a test further out, so
          # it keeps its answer the way any plain name does.
          return "#{prefix}#{second_name_write(node.name, "(#{kept_value_text(node.value, node)})", node)}" if promoted?(node)
          return picked_into_text(node) if picks_into_variable?(node)
          return joined_into_text(node, prefix) if joins_into_variable?(node)

          case @promotion.action_for(node)
          # The line that makes a variable outside a game block sets it wherever it runs after
          # power-on (Writes.variable_set_where_reached).
          when :declare then "#{prefix}#{declaration(node, sets_where_reached: true)}"
          # The line that makes a variable in game code sets it on every pass, as Ruby would.
          when :start then "#{prefix}#{start_text(node)}"
          when :assign then "#{prefix}#{assign_text(node.name, "(#{value_text(node.value)})")}"
          else "#{prefix}#{noted_if_handed(node, local_value_text(node))}"
          end
        end

        # An Array the game keeps as a list of its own (PlainRuby::Arrays), made by the list in
        # place of the Array. `Array.new`'s arguments and block are handed over as written.
        def game_array_text(node)
          made = node.value
          opening = "#{ARRAYS}.list_from_#{made.is_a?(Prism::ArrayNode) ? 'literal' : 'new'}(self, " \
                    "#{game_array_declaration_text(node)}"
          return "#{opening}, #{rewritten_text(made)})" if made.is_a?(Prism::ArrayNode)

          given = made.arguments ? ", #{rewritten_text(made.arguments)}" : ""
          text = "#{opening}#{given})#{" #{rewritten_text(made.block)}" if made.block}"
          # What follows keeps its line number, wherever the arguments started.
          missing = line_ends_between(made.location.start_offset, made.location.end_offset).length - text.count("\n")
          text + ("\n" * [missing, 0].max)
        end

        # `@enemies = Array.new(capacity: 4)`, where the class around it puts things made from a
        # Struct into `@enemies` (LocalNames#instance_variable_things_made): the Array of Structs
        # it makes (DSL::StructArray), named when it is made after the object and the instance
        # variable. Nil for any other write.
        def things_array_text(node)
          made = @names.instance_variable_things_made(node)
          value = node.value
          return nil if made.empty? || !Arrays.makes_array?(value) || !value.is_a?(Prism::CallNode)

          declaration = "#{ARRAYS}::Declaration.new(name: nil, local: :#{node.name.to_s.delete_prefix('@')}, " \
                        "grows: true, source: #{@source_label.inspect}, declared_at: #{place_text(node).inspect}, " \
                        "fraction_at: nil, #{things_text(made)})"
          given = value.arguments ? ", #{rewritten_text(value.arguments)}" : ""
          "#{ARRAYS}.list_from_new(self, #{declaration}#{given})"
        end

        # What the whole block says about the Array +node+ makes (Arrays::Declaration).
        def game_array_declaration_text(node)
          fraction_put = @names.game_array_fraction_put(node)
          "#{ARRAYS}::Declaration.new(name: #{game_array_list_name(node).inspect}, local: :#{node.name}, " \
            "grows: #{@names.game_array_grown?(node)}, source: #{@source_label.inspect}, " \
            "declared_at: #{place_text(node).inspect}, fraction_at: #{(fraction_put && place_text(fraction_put)).inspect}, " \
            "#{things_text(@names.game_array_things_made(node), @names.thing_field_fractions(node))})"
        end

        # What an Array of things made from a class holds (Arrays::Declaration#things): each class
        # written out, read when the line runs, so one defined further down the file is there, and
        # the fields a put shows a fraction for, with +fields_given_fractions+, those a walk gives
        # one (LocalNames#thing_field_fractions).
        def things_text(made, fields_given_fractions = [])
          return "things: nil, thing_fractions: []" if made.empty?

          classes = made.map { |put| rewritten_text(put.receiver) }.uniq.join(", ")
          fractions = (made.flat_map { |put| @names.fraction_fields_of(put) } + fields_given_fractions).uniq
          "things: -> { [#{classes}] }, thing_fractions: #{fractions.inspect}"
        end

        # The list's name: its local's, unique in this block or file (`trail`, then `trail_2` for a
        # second local of that name), and in a file of game code (VBlank.require_game_file) after
        # the file's name, `walker_trail`. So the name never hangs on which line runs first, and a
        # local of one name in two files is two lists.
        def game_array_list_name(node)
          name = @names.variable_name_of(node)
          return name if @source_label.nil? || @source_label.match?(/:\d+\z/)

          :"#{File.basename(@source_label, '.rb')}_#{name}"
        end

        # Where +node+ is, as a message names a place: `game.rb:12`.
        def place_text(node)
          file = @source_label.to_s.sub(/:\d+\z/, "")
          "#{File.basename(file)}:#{node.location.start_line}"
        end

        # A local a `var` line makes keeps the variable as its own (Writes.keep_as_local).
        def local_value_text(node)
          value = kept_value_text(node.value, node)
          return value unless LocalNames.var_call?(node)

          "#{WRITES}.keep_as_local((#{value}), :#{node.name})"
        end

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

        # What a plain local is given: its value, kept as Ruby keeps it where Promotion#kept_copy
        # cannot prove that nothing changes it before it is read.
        #
        # A button read while setting up and kept for game code is noted for the build's warning
        # (Steps.kept_answer's +button_kept+).
        def kept_value_text(value, write)
          kept = @promotion.kept_copy(write).copy
          return objects_followed_text(value) unless kept

          button = ", button_kept: true" if @promotion.button_kept?(write)
          "#{STEPS}.kept_answer((#{value_text(value)}), copy: :#{kept}, name: :#{write.name}#{button})"
        end

        # A plain local given anything but a literal: the objects it holds followed
        # (InstanceVariables.follow_objects_in), since a Struct a plain file made may be among them.
        def objects_followed_text(value)
          return value_text(value) if !@follows_instance_variables || PLAIN_LITERALS.any? { |kind| value.is_a?(kind) }

          "#{INSTANCE_VARIABLES}.follow_objects_in(#{value_text(value)})"
        end

        PLAIN_LITERALS = [Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode, Prism::NilNode,
                          Prism::TrueNode, Prism::FalseNode, Prism::InterpolatedStringNode].freeze

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
          return copied_text(node) unless @promotion.action_for(node)

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

        # Does +value+ read a place one of +targets+ is given first, so it must be read before
        # any is given? An attribute written before (`point.x, point.y = point.y, point.x`) counts for a read of
        # that attribute on any object, since the source cannot tell which objects are the same.
        def reads_target?(value, targets)
          names = targets.filter_map { |target| target.name if target.respond_to?(:name) }
          reads = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode]
          return true if reads.any? { |kind| value.is_a?(kind) } && names.include?(value.name)

          attributes = targets.grep(Prism::CallTargetNode).map { |target| target.name.to_s.delete_suffix("=").to_sym }
          return true if value.is_a?(Prism::CallNode) && value.receiver && value.arguments.nil? && attributes.include?(value.name)

          value.compact_child_nodes.any? { |child| reads_target?(child, targets) }
        end

        def target_write_text(target, value)
          case target
          when Prism::LocalVariableTargetNode then local_target_text(target, value)
          when Prism::InstanceVariableTargetNode
            "#{target.name} = #{write_call(instance_variable_place_text(target.name), value, target.name,
                                           options: ", moves: true#{owner_option}")}"
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

          case @promotion.action_for(target)
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

        def promoted?(node) = @promotion.write_under_test(node).promoted? && !@open_tests.empty?

        def open_tests_text = "[#{@open_tests.join(', ')}]"

        # What stands before a side's code: each name it changes given a variable, if the test
        # turns out to be the game's. There it goes before the branch, where the name's number
        # still holds whichever way the test goes. +outer+ are tests already open around this one.
        def promotions_text(node, sides, answer, outer: @open_tests)
          given = [answer, *outer].join(", ")
          promotions = @promotion.before_test(node, sides)
          names = promotions.names.map do |each_name|
            name = each_name.name
            stays = each_name.on_every_side ? "" : ", may_stay_nil: true"
            "#{name} = #{WRITES}.promote(#{name}, #{given}#{stays}, name: :#{name}); "
          end
          (names + promotions.places.map { |place| place_promotion_text(place, given) }).uniq.join
        end

        # The same for an instance variable, a slot or an attribute.
        def place_promotion_text(promotion, given)
          place = promotion.node
          return slot_promotion_text(place, promotion.keys, given) if promotion.keys

          case place
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode
            owner = @follows_instance_variables ? ", owner: self, label: :#{place.name}" : ""
            "#{place.name} = #{WRITES}.promote_place(#{instance_variable_place_text(place.name)}, #{given}, " \
              "may_stay_nil: true#{owner}); "
          when Prism::CallOperatorWriteNode then attribute_promotion_text(place, place.read_name, given)
          else attribute_promotion_text(place, place.name.to_s.delete_suffix("="), given)
          end
        end

        def slot_promotion_text(place, keys, given)
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
          if @promotion.local(node).plain?
            return "(#{WRITES}.note_handed_name_written(#{node.name}, nil, :#{node.name}); #{copied_text(node)})"
          end

          "#{node.name} = #{change_call(node)}"
        end

        def change_call(node, options = "")
          current = node.name
          if node.is_a?(Prism::InstanceVariableOperatorWriteNode)
            current = instance_variable_place_text(node.name)
            options += owner_option
          end
          "#{WRITES}.change(#{current}, :#{node.binary_operator}, #{argument(node.value)}, #{open_tests_text}, " \
            "#{node.name.to_sym.inspect}#{options}) { |#{NEW_VALUE}| #{NEW_VALUE} }"
        end

        # The right side is a block so plain values keep Ruby's skipping of it.
        def joined_text(node, step, into: nil)
          jump = jump_in(node.right)
          return jump_after_join_text(node, step, jump) if jump

          given = @lone_joins.key?(node) ? ", used: false" : ""
          given = ", into: #{into}" if into
          return join_under_test_text(node, step, given) if @promotion.before_test(node, [node.right]).changes?

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
          return loop_jump_after_join_text(node, step) if @jump_targets.last && !jump.is_a?(Prism::ReturnNode)

          left = "__plain_ruby_#{@answers += 1}"
          right = "(#{rewritten_text(node.right)})"
          sides = step == "join_either" ? "#{left} : #{right}" : "#{right} : #{left}"
          "(#{left} = #{argument(node.left)}; #{STEPS}.answer_before_jump(#{left}, :#{jump_word(jump)}) ? #{sides})"
        end

        # `found && break` or `found || next` in a loop's own body: the right side is a side of a
        # test on the left, as `break if found` is, so a test the game makes can guard the jump.
        def loop_jump_after_join_text(node, step)
          test = fresh_name
          left = argument(node.left)
          left = "#{STEPS}.opposite(#{left})" if step == "join_either"
          right = under_open_test(test) { rewritten_text(node.right) }
          "(#{test} = #{STEPS}.branch_test(#{left}); if #{test}.open_yes_side; #{test}.close_side((#{right})); end; " \
            "#{test}.answer)"
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
          # A body run once before the loop's test (`begin ... end while`) is no loop's yet, so
          # its jumps stay Ruby's, and one under a game test is refused naming the form.
          words = jump_words(node.statements)
          target = node.begin_modifier? ? DO_WHILE_TARGET : test unless words.empty?
          body = under_open_test(test) { with_jump_target(target) { side_body_text(node, shut_at) } }
          first = node.begin_modifier? ? "#{body}; " : ""
          jumps = words.empty? || node.begin_modifier? ? "" : ", jumps: #{words.inspect}"
          "(#{test} = #{STEPS}.#{step}(#{as_written(node.predicate)}#{jumps}) { #{rewritten_text(node.predicate)} }; " \
            "#{first}while #{test}.go_round#{" { #{promotions} }" unless promotions.empty?}; #{body}; end)"
        end

        # The `break` and `next` words written in a loop's own +body+: not in a block, a method or
        # another loop inside it, whose jumps are their own.
        def jump_words(body, found = [])
          return found if body.nil?

          found << :break if body.is_a?(Prism::BreakNode)
          found << :next if body.is_a?(Prism::NextNode)
          body.compact_child_nodes.each do |child|
            next if (OWN_SCOPES + LOOP_NODES).any? { |kind| child.is_a?(kind) }

            jump_words(child, found)
          end
          found.uniq
        end

        # The Jumps a loop whose own +body+ holds a `break` or a `next` is handed, made new; nil
        # for a loop with neither.
        def jumps_text(body)
          words = jump_words(body)
          "#{LOOP_JUMPS}.new(#{words.inspect})" unless words.empty?
        end

        # The loop whose body is being rewritten, for the `break` and `next` in it to name
        # (#jump_text): +target+ is the name of its LoopTest or Jumps as the rewritten block runs.
        # A loop with no jumps of its own is still pushed, as nil, so none further out is named.
        def with_jump_target(target)
          @jump_targets.push(target && [target, @open_tests.length])
          yield
        ensure
          @jump_targets.pop
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

          if kept
            note_answer_tail(node.statements)
            note_answer_tail(other_side(node).statements) if other_side(node).is_a?(Prism::ElseNode)
          end
          answer = "__plain_ruby_#{@answers += 1}"
          shut_at = node.end_keyword_loc&.start_offset || node.location.end_offset
          promotions = promotions_text(node, [node.statements, other_side(node)], answer)
          watched = kept ? nil : flag_tested(node)
          sides = under_open_test(answer) do
            "#{yes_side_text(node, answer, shut_at, kept)}#{no_side_text(node, answer, shut_at, kept)}"
          end
          return watched_flag_reads_text(node, answer, kept, "#{promotions}#{sides}") if !watched && @follows_instance_variables

          watch = watched ? "#{answer}.watch_flag(#{flag_watch_arguments(node, watched)}); " : ""
          "(#{answer} = #{STEPS}.branch_test(#{test_text(node)}); #{watch}#{promotions}#{sides}#{answer}.#{value_step(kept)})"
        end

        # A conditional whose test is no instance variable standing alone (`if door.open?`), or
        # one written for its value (`@open ? 1 : 0`): the plain flags read while its test runs,
        # through a reader as well, are watched as `if @open` watches its own
        # (Steps::BuildTest#watch_flag_reads).
        def watched_flag_reads_text(node, answer, kept, rest)
          mark = "#{answer}_flag_reads"
          watch = "#{answer}.watch_flag_reads(#{INSTANCE_VARIABLES}.flag_reads_since(#{mark}), " \
                  "#{flag_watch_settings(node)}, picks: #{kept ? true : false}); "
          "(#{mark} = #{INSTANCE_VARIABLES}.flag_read_mark; #{answer} = #{STEPS}.branch_test(#{test_text(node)}); " \
            "#{watch}#{rest}#{answer}.#{value_step(kept)})"
        end

        # The instance variable a conditional tests standing alone (`if @open`, `unless @planned`,
        # `if !@open`), where the rewrite follows instance variables, or nil. A plain `true` or
        # `false` tested so is a once-guard or a game flag, and what its sides record tells which
        # (Steps::BuildTest#watch_flag).
        def flag_tested(node)
          return unless @follows_instance_variables

          tested = node.predicate
          tested = tested.receiver if tested.is_a?(Prism::CallNode) && tested.name == :! && tested.arguments.nil?
          tested.name if tested.is_a?(Prism::InstanceVariableReadNode)
        end

        # What BuildTest#watch_flag is handed: the object, the instance variable and what it holds
        # now, where the test is written (so a side skipped here can be matched with the same side
        # run where the build reached the line before or after), and whether each side records
        # nothing whatever runs it, read off the source: nothing written, a `return`, `break` or
        # `next` alone, or a `raise`, which stops the build (`raise ArgumentError, "..." if @written`,
        # a guard on how the game is put together).
        def flag_watch_arguments(node, name) = "self, :#{name}, #{name}, #{flag_watch_settings(node)}"

        def flag_watch_settings(node)
          other = other_side(node)
          quiet_no = other.nil? || (other.is_a?(Prism::ElseNode) && quiet_side?(other.statements))
          site = "#{@source_label}:#{node.location.start_offset}"
          "site: #{site.inspect}, quiet_yes: #{quiet_side?(node.statements)}, quiet_no: #{quiet_no}"
        end

        def quiet_side?(statements)
          statements.nil? || statements.body.all? { |statement| quiet_statement?(statement) }
        end

        def quiet_statement?(statement)
          return true if statement.is_a?(Prism::CallNode) && statement.receiver.nil? && %i[raise fail].include?(statement.name)

          JUMPS.any? { |kind| statement.is_a?(kind) } &&
            (statement.arguments.nil? || statement.arguments.arguments.all? { |given| LITERALS.any? { |kind| given.is_a?(kind) } })
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
          [*node.conditions, node.else_clause].compact.each { |arm| note_answer_tail(arm.statements) } if kept
          chain = arm_text(node, 0, subject, kept)
          chain = scene_dispatch_text(node, subject, chain) if !kept && value_unused?(node) && scene_dispatch_shape?(node)
          "(#{given}#{breaks}#{chain})"
        end

        # Does nothing read what +node+ gives back? It stands as a statement of its own, and not as
        # the last line of a method or of a block whose verb reads its last line. `x = (case ...)`
        # is no statement: the parentheses are.
        def value_unused?(node) = @whole_statements.key?(node) && !@answer_tails.key?(node)

        # A ternary whose number something reads where it stands, inside a sum or as a verb's
        # argument: its sides keep their answer as `x = test ? a : b` does (Steps' picked_value),
        # since a test the game makes has no answer of its own to hand on. One standing alone, or
        # ending a method (#conditional_text's :tail), is left as it was.
        def ternary_read?(node)
          node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil? && !value_unused?(node) &&
            !@tail_ternaries.key?(node)
        end

        # A `case` that picks a scene by a number: a subject, `when`s of whole numbers or
        # constants, each arm one `call :name` and nothing else, and no `else` or an empty one.
        # Whether the subject is a game variable and each name a scene is known only as the line
        # runs (Builder::Scenes#scene_case?).
        def scene_dispatch_shape?(node)
          node.is_a?(Prism::CaseNode) && node.predicate && node.else_clause&.statements.nil? &&
            node.conditions.all? do |arm|
              arm.conditions.all? { |choice| SCENE_DISPATCH_VALUES.any? { |kind| choice.is_a?(kind) } } &&
                lone_named_call?(arm.statements)
            end
        end

        # What a `when` of a scene dispatch can hold: a whole number or a constant naming one.
        SCENE_DISPATCH_VALUES = [Prism::IntegerNode, Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

        # `call :name`, alone on its side.
        def lone_named_call?(statements)
          call = statements&.body&.first
          statements.body.one? && call.is_a?(Prism::CallNode) && call.name == :call && call.receiver.nil? &&
            call.block.nil? && call.arguments&.arguments&.one? && call.arguments.arguments.first.is_a?(Prism::SymbolNode)
        end

        # The scene dispatch (a case node) where the line turns out to pick scenes, and the
        # chain of tests where it does not. The arms are worked out once, before either.
        def scene_dispatch_text(node, subject, chain)
          arms = node.conditions.map do |arm|
            values = arm.conditions.map { |choice| rewritten_text(choice) }.join(", ")
            "[[#{values}], #{arm.statements.body.first.arguments.arguments.first.slice}]"
          end
          held = "__plain_ruby_#{@answers += 1}"
          "#{held} = [#{arms.join(', ')}]; if ::VBlank::Builder === self && scene_case?(#{subject}, #{held}) " \
            "then emit_scene_case(#{subject}, #{held}) else #{chain} end"
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

          @in_text += 1
          "\#{#{STEPS}.text_piece((#{rewritten_text(node.statements)}))}"
        ensure
          @in_text -= 1 unless node.statements.nil?
        end

        # `for x in list`. Ruby runs it while the game is built, as it runs `each`. A range with a
        # number the game keeps at an end has no length yet, so Steps.for_range refuses it, and
        # Steps.for_collection refuses a game's own list or pool, whose items the game holds.
        #
        # A `break` or `next` in its body is the loop's (#jump_text): the range is handed the
        # loop's Jumps, made where the range is.
        def for_text(node)
          collection = node.collection
          jumps = jumps_text(node.statements)
          target = jumps && fresh_name
          made = target ? ", #{target} = #{jumps}" : ""
          given =
            if collection.is_a?(Prism::RangeNode)
              from = collection.left ? argument(collection.left) : "nil"
              upto = collection.right ? argument(collection.right) : "nil"
              "#{STEPS}.for_range(#{from}, #{upto}, #{collection.exclude_end?}#{made})"
            else
              "#{STEPS}.for_collection(#{argument(collection)}#{made})"
            end
          between(node.location.start_offset, collection.location.start_offset) + given +
            with_jump_target(target) { copied_text(node, from: collection.location.end_offset) }
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

        # A loop's test as the author wrote it, as a String literal on one line, for the words a
        # step says when the test is a game number standing alone (Steps.refuse_number_as_loop_test!).
        def as_written(node) = node.slice.inspect

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

          %i[assign start].include?(@promotion.action_for(write)) && !@names.first_write?(write)
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
            @promotion.action_for(write) == :assign && !@names.keeps_truth?(write)
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
