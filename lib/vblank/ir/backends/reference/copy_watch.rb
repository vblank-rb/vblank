# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Reference
        # WHICH KEPT COPIES DIFFERED FROM WHAT THEY WERE COPIED FROM, for Cartridge::Game#
        # copies_that_differed. A plain Ruby local set from a game value keeps the number of its
        # line in a hidden variable (DSL::PlainRuby::Steps.kept_answer), as Ruby's local does. A
        # game written while such a local followed its variable may lean on the old live read
        # without knowing it, and then plays differently with no error anywhere.
        #
        # An interpreter extended with this remembers, for each watched copy, the value node it
        # was last set from and the number it got. Each time the game reads the copy, the node is
        # worked out again: what the local would have read had it followed its source. Where the
        # two differ, the copy is named, with the first frame it happened on and how many reads
        # did. A copy the game has changed since its set (`kept += 1`) is no longer a copy of
        # anything, and is not compared.
        #
        # An instance that is not extended runs exactly as before, so a normal run pays nothing.
        module CopyWatch
          # What the build knows of one copy: the game's line that kept it (`"file.rb:12"`) and the
          # local it holds the number of, or nil.
          CopyLine = Data.define(:source, :local)

          # One copy that differed: its line and local, the game variables its source reads, the
          # number it kept and the one its source read instead, on the first +frame+ that
          # happened, and how many +times+ a read differed in the run.
          Difference = Data.define(:source, :local, :variables, :kept, :live, :frame, :times) do
            def described
              from = variables.empty? ? "its source" : variables.join(", ")
              "#{source}  #{local || 'a kept number'} kept #{kept} where #{from} read #{live}, " \
                "frame #{frame} (#{times} #{times == 1 ? 'read' : 'reads'} differed)"
            end
          end

          # Watch +copies+, a Hash of the hidden variable's name to its CopyLine. Returns self.
          def watch_copies(copies)
            @watched_copies = copies
            @copy_sets = {}
            @copy_differences = {}
            @comparing_copy = false
            self
          end

          # Every copy that differed, in the order each first did.
          def copy_differences = @copy_differences.values

          def exec_set(node)
            super
            @copy_sets[node.var] = [node.value, @vars[node.var]] if @watched_copies.key?(node.var)
          end

          # A kept test's answer is set by an `if` on the test, 1 on its yes side and 0 on its no side
          # (DSL::PlainRuby::Writes.store_answer). Its source is the test, read as 1 or 0.
          def exec_if(node)
            super
            kept = kept_answer_variable(node) or return
            @copy_sets[kept] = [TestAnswer.new(node.cond), @vars[kept]]
          end

          # A test whose answer a copy keeps, worked out as the 1 or 0 the copy was given.
          TestAnswer = Data.define(:cond)

          def value_of_var_ref(node)
            number = super
            compare_copy(node.name, number) if !@comparing_copy && @watched_copies.key?(node.name)
            number
          end

          private

          def compare_copy(name, number)
            source, number_set = @copy_sets[name]
            return if source.nil? || number != number_set

            live = source_number_now(source)
            return if live.nil? || live == number

            earlier = @copy_differences[name]
            @copy_differences[name] = earlier ? earlier.with(times: earlier.times + 1) : first_difference(name, source, number, live)
          end

          # The source worked out now, reading no copy as a read of the game's; nil where it cannot
          # be (a list read past the list's end now).
          def source_number_now(source)
            @comparing_copy = true
            return eval_value(source) unless source.is_a?(TestAnswer)

            eval_value(source.cond).zero? ? 0 : 1
          rescue ProgramError
            nil
          ensure
            @comparing_copy = false
          end

          # The watched copy +node+ sets to 1 on its yes side and 0 on its no side, or nil.
          def kept_answer_variable(node)
            yes = node.children
            no = node.else&.children
            return unless yes.length == 1 && no&.length == 1

            kept = [yes.first, no.first].map { |side| side.kind == :set && side.value.kind == :int && side.var }.uniq
            return unless kept.length == 1 && kept.first && @watched_copies.key?(kept.first)
            return unless yes.first.value.value == 1 && no.first.value.value.zero?

            kept.first
          end

          def first_difference(name, source, kept, live)
            line = @watched_copies.fetch(name)
            source = source.cond if source.is_a?(TestAnswer)
            variables = source.is_a?(Node) ? source.walk.select { |each| each.kind == :var_ref }.map(&:name).uniq : []
            Difference.new(source: line.source, local: line.local, variables: variables, kept: kept, live: live,
                           frame: @frame, times: 1)
          end
        end
      end
    end
  end
end
