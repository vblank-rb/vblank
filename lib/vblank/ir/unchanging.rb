# frozen_string_literal: true

module VBlank
  module IR
    # Which values change nothing by being worked out. `and` and `or` work both sides out, always, in
    # the interpreter. A console skips the right side when the left has decided, and that is the
    # same thing only where nobody could tell. A list read past its end stops the game, so it counts
    # as a change. A chance's number was drawn before the test, so asking it changes nothing.
    module Unchanging
      PARTS = Ractor.make_shareable(
        { int: [], var_ref: [], list_len: [], held: [], pressed: [], pulled: [], players_connected: [], local_player: [],
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

      # The kinds of working-out whose number depends on the variables it reads and on nothing
      # else: no button, no list, no clock, which change without a statement naming them.
      READ_ONLY_VARIABLES = %i[int var_ref binop neg bit_not absolute shift_right clamped table_get mul_fix div_fix].freeze

      # The statements that change one variable, and the operand naming it.
      VARIABLE_WRITERS = Ractor.make_shareable({ set: :var, add: :var, sub: :var, negate: :var, abs: :var,
                                                 negate_abs: :var, clamp: :var, copy: :dest })

      # The statements that only draw, changing no variable, list or anything a working-out reads.
      ONLY_DRAWING = %i[pixel fill_rect draw_rect_at blit blit_pose draw_text draw_digit clear_screen
                        draw_column_at fill_face].freeze

      # A test changes what its sides change, and nothing more.
      TESTS = %i[if else].freeze

      # Does +statement+, and everything it holds, leave every variable in +read+ alone? Yes only
      # with a proof: each node is a working-out, a test, a draw, or a change to a variable not in
      # +read+. Anything else counts as a change (a call can change anything, a wait lets the
      # frame's timers run), so a missed proof keeps a copy, never gives a wrong number.
      def self.left_alone_by?(statement, read) = statement.walk.all? { |node| leaves_variables?(node, read) }

      # The variables +node+ reads, or nil where it reads anything else.
      def self.variables_read(node)
        names = []
        node.walk do |each_node|
          return nil unless READ_ONLY_VARIABLES.include?(each_node.kind)

          names << each_node.name if each_node.kind == :var_ref
        end
        names
      end

      # Does +node+, met inside a statement, leave every variable in +read+ alone?
      def self.leaves_variables?(node, read)
        return true if node.value? || ONLY_DRAWING.include?(node.kind) || TESTS.include?(node.kind)

        operand = VARIABLE_WRITERS[node.kind]
        !operand.nil? && !read.include?(node.operand_named(operand))
      end
    end
  end
end
