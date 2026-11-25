# frozen_string_literal: true

module VBlank
  module DSL
    # The open `if` Condition#record_branch just recorded, waiting for an optional other side. On
    # its own it does nothing; #else fills in the branch that runs when the test was false.
    class Branch # :nodoc:
      def initialize(builder, if_node)
        @builder = builder
        @if_node = if_node
      end

      # Statements to run when the test was false.
      def else(&block)
        @builder.record_else(@if_node, &block)
        nil
      end
    end
  end
end
