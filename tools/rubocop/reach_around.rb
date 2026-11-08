# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module VBlank
      # A CALL MADE AROUND AN OBJECT, rather than to it by name: `send`, `public_send` or `__send__`
      # with the method's name as data, `method(:name)` handed on in place of the object, or an
      # object's instance variables read or written from outside it. Each hides the call from
      # anybody grepping for the method's name, and most reach past what the object chose to show.
      #
      # The fix is to call the method by its name: on the object (made public, if somebody outside
      # really asks it), through a block that calls it, or by a written-out `case` where the name
      # comes from a table. Where reaching around IS the point, the way the plain-Ruby rewriter
      # applies the operator a game wrote, the file goes in this cop's Exclude in .rubocop.yml,
      # with a comment saying why.
      #
      # The pre-commit hook runs this cop on the Ruby files being committed (.githooks/pre-commit),
      # and `rake rubocop` on the whole tree.
      class ReachAround < Base
        MSG = "`%<call>s` calls around the object, so the call cannot be found by its name. Call the " \
              "method by name: on the object, through a block, or by a `case` over the names. If this " \
              "is Ruby itself on purpose, add the file to VBlank/ReachAround's Exclude in .rubocop.yml, " \
              "with a comment saying why."

        SENDS = %i[send public_send __send__].freeze
        READS = %i[instance_variable_get instance_variable_set].freeze
        RESTRICT_ON_SEND = (SENDS + READS + %i[method]).freeze

        def on_send(node)
          return unless reaching?(node)

          add_offense(node.loc.selector, message: format(MSG, call: node.method_name))
        end
        alias on_csend on_send

        private

        # `send(...)` with a name to send, `instance_variable_get(:@x)`, or `method(:name)`. A
        # `send` with nothing given (a socket's own, say) or `method` with no Symbol is something
        # else that happens to share the word.
        def reaching?(node)
          case node.method_name
          when *SENDS, *READS then !node.arguments.empty?
          when :method then node.arguments.size == 1 && node.first_argument.sym_type?
          else false
          end
        end
      end
    end
  end
end
