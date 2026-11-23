# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # A Struct's own methods, read as game code wherever the Struct was written.
      #
      # A walk of an Array of Structs hands its block an object of the game's Struct
      # (DSL::StructArray), so the Struct's methods run on it as the game is built. A method in a
      # file VBlank never read as game code, one brought in with plain `require` or the game's own
      # main file, runs as Ruby wrote it: `x > 5 ? 3 : 1` asks a test the game makes, which is
      # always there while building, and takes the `3` side for good. So each method is read
      # again from its file, rewritten as a game file's would be, and defined on the class of what
      # the walk hands over, where it stands in front of the Struct's own.
      module StructMethods
        module_function

        # Every method +kind+, and each class and module it is made from up to Struct, defines with
        # `def`, rewritten as game code onto +walked+. The furthest are defined first, so the
        # nearest wins as Ruby's lookup would have it.
        def define_on(walked, kind)
          kind.ancestors.take_while { |mod| mod != Struct }.reverse_each do |mod|
            (mod.instance_methods(false) + mod.private_instance_methods(false)).each do |name|
              file, line = mod.instance_method(name).source_location
              next if file.nil? || PlainRuby.library_file?(file)

              define_one(walked, kind, name, file, line)
            end
          end
        end

        # The method +name+ written at +file+:+line+, rewritten onto +walked+. A method with no code
        # of its own there (`attr_accessor`) is left as it is.
        def define_one(walked, kind, name, file, line)
          refuse_unreadable!(kind, name, file, line) unless File.file?(file)
          source, scopes = PlainRuby.parsed_file(file)
          written = scopes.fetch(line, [])
          definition = written.find { |node| node.is_a?(Prism::DefNode) && node.receiver.nil? }
          if definition.nil?
            refuse_unreadable!(kind, name, file, line) unless written.empty?
            return
          end

          text = Rewriter.new(source, source_label: File.expand_path(file), follows_instance_variables: true)
                         .rewritten(definition)
          define_text(walked, text, modules_around(tree_of(file), definition), file, definition.location.start_line)
          walked.alias_method(name, definition.name) unless name == definition.name
        end

        # +text+, a method's definition, defined on +walked+ inside the classes and modules
        # +around+ it, as they were written, so the constants it names are the ones it named.
        def define_text(walked, text, around, file, line)
          openings = around.map { |mod| "#{mod.is_a?(Prism::ClassNode) ? 'class' : 'module'} #{mod.constant_path.slice}" }
          code = [*openings, "::VBlank::DSL::PlainRuby::StructMethods.defining.class_eval do", text, "end",
                  *(["end"] * openings.length)].join("\n")
          Ractor.current[:plain_ruby_struct_defining] = walked
          # The opening lines stand above the method's own, so it keeps its line number.
          Object.class_eval(code, file, line - openings.length - 1) # rubocop:disable Security/Eval
        ensure
          Ractor.current[:plain_ruby_struct_defining] = nil
        end

        # The class a method is being defined on (#define_text).
        def defining = Ractor.current[:plain_ruby_struct_defining]

        # The `class` and `module` lines around +target+ in +node+, the outermost first. The two
        # come from two reads of the file, so +target+ is found by where it stands.
        def modules_around(node, target, around = [])
          return around if node.is_a?(Prism::DefNode) && node.location.start_offset == target.location.start_offset

          inner = node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ? around + [node] : around
          node.compact_child_nodes.each do |child|
            next unless child.location.start_offset <= target.location.start_offset &&
                        child.location.end_offset >= target.location.end_offset

            found = modules_around(child, target, inner)
            return found if found
          end
          nil
        end

        # The whole of +file+ as Prism reads it, once per Ractor, since a tree is not shared.
        def tree_of(file)
          trees = (Ractor.current[:plain_ruby_struct_trees] ||= {})
          trees[file] ||= Prism.parse(PlainRuby.parsed_file(file).first).value
        end

        def refuse_unreadable!(kind, name, file, line)
          raise Refused, "VBlank cannot read the method `#{name}` of `#{StructSettings.name_of(kind)}` as game code, " \
                         "because it is not made with `def`. (at #{File.basename(file)}:#{line}) To fix this, write " \
                         "it with `def` in the block of `Struct.new`."
        end
      end
    end
  end
end
