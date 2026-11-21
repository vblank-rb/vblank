# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # How often a run names each variable, counted from the program before anything is lowered, so
      # a lowering whose console has a little memory that is quicker to reach than the rest can keep
      # the busiest variables there.
      #
      # Each place a statement or a value names a variable counts once, times LOOP_WEIGHT for every
      # loop around it, so a number worked on in the loop a routine goes round counts for more than
      # one set once a pass. A routine counts where it is called: what it names, times the weight of
      # each call. Nothing is run, so a loop's turns are not known: the weight is a ranking, not a
      # count of reads and writes.
      class VariableUse
        # What each loop around a statement multiplies its count by: a loop goes round more than
        # once, and how often is not known before the game runs.
        LOOP_WEIGHT = 8

        # The kinds of statement whose body goes round.
        LOOP_KINDS = %i[loop repeat].freeze

        def initialize(program)
          @funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
          @routine_counts = {}
          @counting = Set.new
          @counts = Hash.new(0)
          count_under(program, 1, @counts)
        end

        # The weighted count of +name+: nought for a variable a run never names.
        def weight(name) = @counts[name]

        private

        def count_under(node, weight, counts)
          Reach::VARIABLES_OF[node.kind]&.call(node)&.each { |name| counts[name] += weight }
          Reach.routines_named([node]).each do |routine|
            routine_counts(routine).each { |name, count| counts[name] += count * weight }
          end
          inner = LOOP_KINDS.include?(node.kind) ? weight * LOOP_WEIGHT : weight
          (node.children + node.operand_nodes).each do |child|
            count_under(child, inner, counts) unless child.kind == :func
          end
        end

        # What one call of the routine +name+ names, the routines it calls included. A routine that
        # calls itself is refused before anything is lowered (LoweringPlan#refuse_unbuildable!), so
        # one met again while it is being counted adds nothing.
        def routine_counts(name)
          return {} unless @funcs.key?(name) && !@counting.include?(name)

          @routine_counts.fetch(name) do
            @counting << name
            counts = Hash.new(0)
            count_under(@funcs.fetch(name), 1, counts)
            @counting.delete(name)
            @routine_counts[name] = counts
          end
        end
      end
    end
  end
end
