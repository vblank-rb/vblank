# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # Refuses what a game block cannot use, before any of it runs.
      #
      # NOTHING HERE LISTS WHAT IS BANNED, except a few calls that have no constant to look at.
      # There is no end of gems and libraries, so a name in the block is refused unless it is
      # known to be the game's own, VBlank's, or a harmless piece of Ruby. These checks catch
      # mistakes. They are not a wall: the game's own helper in another file can call anything.
      #
      # THE CALLS ARE CHECKED AS THE GAME IS DECLARED, from the source alone. The constants wait
      # until the game is built, since one defined lower down the author's file is not there
      # yet, so what they need goes into the rewritten block as plain data (see #constant_check).
      class BlockChecks
        # Ruby's values and the modules that work on them, which reach nothing outside the game.
        RUBY_VALUES = %i[Array Comparable Float Hash Integer Math Range Rational String Symbol].freeze
        # Ruby's own errors, which reach nothing outside the game either: a game raises one to stop
        # its build with words of its own (`raise ArgumentError, "A speed is from 1 to 8."`).
        RUBY_ERRORS = %i[ArgumentError FrozenError IndexError KeyError NameError NoMethodError
                         NotImplementedError RangeError RuntimeError StandardError StopIteration
                         TypeError ZeroDivisionError].freeze
        # The constants game code may name that are not the game's own.
        RUBY_BASICS = (RUBY_VALUES + RUBY_ERRORS).freeze

        # What reaches outside the game with no constant to see: Ruby's own short list. These
        # are only Ruby's when nothing stands in front of them. `sparks.spawn` is a game verb
        # and `save.load` another, and neither is Ruby's `spawn` or `load`.
        OUTSIDE_CALLS = %i[abort at_exit binding eval exec exit exit! fork load open require
                           require_relative sleep spawn syscall system trap].freeze

        # ...and what gets round the checks whatever it is called on.
        INDIRECT_CALLS = %i[__send__ class_eval const_get instance_eval public_send send].freeze

        # ...and what reads inside an object, whatever it is called on, given an argument: the calls
        # VBlank/ReachAround (tools/rubocop/reach_around.rb) refuses in the library's own code. A
        # `method` with no argument may be a game's own field of that name, so it is left alone.
        REACHING_IN_CALLS = %i[instance_variable_get instance_variable_set method].freeze

        # What only game code calls, so a file holding one is game code. These need a block, since
        # `scene` or `func` alone could be a method of the file's own. `var` needs a name instead.
        GAME_BLOCK_VERBS = (LocalNames::GAME_VERBS - %i[every after repeat item]).freeze

        # +folder+ is one folder of the game's, or several. +defined_only+ leaves alone a name not
        # defined yet, which a file of the game may name before a later one defines it.
        def self.refuse_outside_constant!(constants, nesting:, folder:, allow:, file:, defined_only: false)
          library = library_folder
          constants.each do |name, line|
            next if RUBY_BASICS.include?(name) || allow.include?(name.to_s)
            next if defined_only && !constant_defined_in_nesting?(name, nesting)
            next if game_constant?(name, nesting, [*Array(folder), library])

            raise Refused, "`#{name}` is not part of your game, so this block cannot use it. This " \
                           "block describes what the game does as it plays. If you need `#{name}` " \
                           "while building, use it above the block and keep the result in a " \
                           "constant. If this library is safe here, add it with `allow:`. " \
                           "(at #{file}:#{line})"
          end
        end

        def self.library_folder = "#{VBlank.root.join('lib')}/"

        def self.game_constant?(name, nesting, folders)
          owner = nesting.find { |mod| mod.const_defined?(name, false) } || Object
          return false unless owner.const_defined?(name)

          file, = owner.const_source_location(name)
          # Ruby keeps the path a file was started by, which `ruby game.rb` leaves relative.
          !file.nil? && folders.any? { |folder| File.expand_path(file).start_with?(folder) }
        end
        private_class_method :game_constant?

        def self.constant_defined_in_nesting?(name, nesting) = (nesting + [Object]).any? { |mod| mod.const_defined?(name) }
        private_class_method :constant_defined_in_nesting?

        def initialize(block_node, file:, allow:)
          @block_node = block_node
          @file = file
          @allow = allow.map(&:to_s)
        end

        def refuse_outside_calls!(node = @block_node)
          refuse_call!(node)
          node.compact_child_nodes.each { |child| refuse_outside_calls!(child) }
        end

        # A WHOLE FILE OF A GAME (DSL::PlainRuby.rewritten_file). What its methods and blocks do is
        # game code, checked as a game block is. Its other lines run once as the file is loaded,
        # setting up as the lines above a game block do (bringing in files, making constants with
        # `Ractor.make_shareable`), so they are plain Ruby. A plain file it loads that holds game
        # code is the game block's check to find (#refuse_game_code_in_plain_files! follows each
        # file the block's file brings in), as the game is built.
        def refuse_outside_calls_in_file!
          game_code_in(@block_node).each { |node| refuse_outside_calls!(node) }
        end

        # A number set above the block and changed by game code would change once, while building,
        # and the game would never see it. It cannot be made to work: a game can be built more
        # than once, and a variable left in that outside name would belong to one build. Reading
        # the number is fine.
        def refuse_changed_outside_locals!(writes)
          return if writes.empty?

          name = writes.first.name
          raise Refused, "`#{name}` is set outside the game block, so the game cannot change it. To fix " \
                         "this, move the line that sets `#{name}` into the block. " \
                         "(at #{File.basename(@file)}:#{writes.first.location.start_line})"
        end

        # A line of game code in a file `require_relative` brought in is not read as a game: a
        # plain `state = 1` there sets a Ruby name, and nothing ever says so. Looking only at
        # what a file calls keeps this a read of the few files a game names.
        def refuse_game_code_in_plain_files!(from = @file, seen = [])
          files_loaded_by(from, :require_game_file).each { |path, _line| refuse_game_code_in_plain_files!(path, seen) }
          files_loaded_by(from, :require_relative).each do |path, line|
            next if seen.include?(path) || library_file?(path)

            seen << path
            refuse_plain_file!(path, from, line) if game_code?(Prism.parse_file(path).value)
            refuse_game_code_in_plain_files!(path, seen)
          end
        end

        # The call that refuses this block's outside constants, as Ruby source. It reads
        # Module.nesting where it runs, which is how the block's own scope is known.
        def constant_check
          "::VBlank::DSL::PlainRuby::BlockChecks.refuse_outside_constant!(#{constants_named.inspect}, " \
            "nesting: Module.nesting, folder: #{"#{File.dirname(File.expand_path(@file))}/".inspect}, " \
            "allow: #{@allow.inspect}, file: #{File.basename(@file).inspect})"
        end

        # The same for a whole file of a game, to stand at its end: by then the file has defined
        # its own constants. A file may name a constant a later file of the game defines, which
        # is left alone, as are constants defined in its folder, in the game's project
        # (#project_folder), or in +loaded_from+, the folder of the
        # file that brought it in. It reads Module.nesting at the top of the file, so a name inside
        # one of the file's modules is looked up from Object, and is left alone if not found there.
        def file_constant_check(loaded_from:)
          part = File.dirname(File.expand_path(@file))
          folders = [part, File.expand_path(loaded_from), project_folder(part)].compact.uniq.map { |folder| "#{folder}/" }
          named = game_code_in(@block_node).flat_map { |node| constants_named(node) }
          "::VBlank::DSL::PlainRuby::BlockChecks.refuse_outside_constant!(#{named.inspect}, " \
            "nesting: Module.nesting, folder: #{folders.inspect}, allow: [], " \
            "file: #{File.basename(@file).inspect}, defined_only: true)"
        end

        private

        # A file of VBlank's own library, which builds games and is never one: under the library
        # that is loaded, or the front door of another copy of it. A game file names the library by
        # its path (`require_relative "../lib/vblank"`), and that copy need not be the one running:
        # a tool that measures one library against another loads its own and turns the game's
        # require into nothing, and the library's own files call verbs with blocks as they build.
        def library_file?(path)
          return true if path.start_with?(self.class.library_folder)

          File.basename(path) == "vblank.rb" && File.file?(File.join(File.dirname(path), "vblank", "root.rb"))
        end

        # PROJECT_MARKERS are what a game's own folder holds at its top.
        PROJECT_MARKERS = %w[Gemfile .git].freeze

        # The game's own project, the nearest folder above +folder+ holding a Gemfile or a .git, so
        # a part in a folder of its own may name a constant the game's main file defines. Nil when
        # there is none.
        def project_folder(folder)
          Pathname(folder).ascend.find { |dir| PROJECT_MARKERS.any? { |marker| dir.join(marker).exist? } }&.to_s
        end

        # The outermost methods, blocks and lambdas in +node+: the code a file of a game runs as
        # the game plays.
        def game_code_in(node)
          return [node] if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          node.compact_child_nodes.flat_map { |child| game_code_in(child) }
        end

        def files_loaded_by(from, verb)
          loading_calls(Prism.parse_file(from).value, verb).filter_map do |call|
            argument = call.arguments&.arguments&.first
            next unless argument.is_a?(Prism::StringNode)

            path = File.expand_path("#{argument.unescaped.delete_suffix('.rb')}.rb", File.dirname(from))
            [path, call.location.start_line] if File.file?(path)
          end
        end

        def loading_calls(node, verb)
          own = node.is_a?(Prism::CallNode) && node.name == verb ? [node] : []
          own + node.compact_child_nodes.flat_map { |child| loading_calls(child, verb) }
        end

        def game_code?(node)
          return true if game_call?(node)

          node.compact_child_nodes.any? { |child| game_code?(child) }
        end

        def game_call?(node)
          return false unless node.is_a?(Prism::CallNode) && node.receiver.nil?
          return node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) if node.name == :var

          GAME_BLOCK_VERBS.include?(node.name) && node.block.is_a?(Prism::BlockNode)
        end

        def refuse_plain_file!(path, from, line)
          name = File.basename(path, ".rb")
          raise Refused, "`#{File.basename(path)}` holds game code, and it comes in with `require_relative`, " \
                         "so VBlank does not read it as a game. To fix this, load it with " \
                         "`VBlank.require_game_file \"#{name}\"`. (at #{File.basename(from)}:#{line})"
        end

        def constants_named(node = @block_node)
          case node
          when Prism::ConstantReadNode then [[node.name, node.location.start_line]]
          when Prism::ConstantPathNode then [[first_name_of(node), node.location.start_line]]
          else node.compact_child_nodes.flat_map { |child| constants_named(child) }
          end
        end

        def first_name_of(path)
          path = path.parent while path.is_a?(Prism::ConstantPathNode) && path.parent
          path.is_a?(Prism::ConstantReadNode) ? path.name : :Object
        end

        def refuse_call!(node)
          case node
          when Prism::XStringNode, Prism::InterpolatedXStringNode then refuse_backticks!(node)
          when Prism::CallNode
            refuse_reaching_in!(node)
            refuse_outside_call!(node)
          end
        end

        def refuse_outside_call!(node)
          return unless INDIRECT_CALLS.include?(node.name) || (node.receiver.nil? && OUTSIDE_CALLS.include?(node.name))

          refuse!("`#{node.name}` reaches outside the game, so this block cannot use it. If you need " \
                  "it while building, use it above the block and keep the result in a constant.", node)
        end

        def refuse_reaching_in!(node)
          return unless REACHING_IN_CALLS.include?(node.name) && node.arguments

          refuse!("`#{node.name}` reads inside an object, so this block cannot use it. To fix this, call the " \
                  "method by its name.", node)
        end

        def refuse_backticks!(node)
          refuse!("Backticks run a command outside the game, so this block cannot use them. If you " \
                  "need one while building, use it above the block and keep the result in a constant.", node)
        end

        def refuse!(message, node)
          raise Refused, "#{message} (at #{File.basename(@file)}:#{node.location.start_line})"
        end
      end
    end
  end
end
