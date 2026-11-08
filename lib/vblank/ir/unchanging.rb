# frozen_string_literal: true

module VBlank
  module IR
    # WHICH VALUES CHANGE NOTHING BY BEING WORKED OUT. `and` and `or` work both sides out, always, in
    # the interpreter. A console skips the right side when the left has decided, and that is the
    # same thing only where nobody could tell. A list read past its end stops the game, so it counts
    # as a change. A chance's number was drawn before the test, so asking it changes nothing.
    module Unchanging
      PARTS = Ractor.make_shareable(
        { int: [], var_ref: [], list_len: [], held: [], pressed: [], players_connected: [], local_player: [],
          neg: [:operand], bit_not: [:operand], absolute: [:operand], shift_right: [:operand],
          clamped: %i[operand min max], chance: [:draw], table_get: [:index],
          binop: %i[lhs rhs], mul_fix: %i[lhs rhs], div_fix: %i[lhs rhs] }
      )

      # Whether working +node+ out changes nothing. The block returns whether a part is a number the
      # lowering already knows.
      def self.value?(node, &known)
        return true if known&.call(node)

        parts = PARTS[node.kind]
        !parts.nil? && parts.all? { |part| value?(node.operand_named(part), &known) }
      end
    end
  end
end
