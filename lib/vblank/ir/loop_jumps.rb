# frozen_string_literal: true

module VBlank
  module IR
    # Ruby's `break` and `next` in a loop (Nodes::BreakRepeat, Nodes::NextRepeat), and which loop
    # each belongs to.
    #
    # A jump names no loop. It belongs to the nearest `repeat` above it, and it may sit only under
    # tests on the way there: a jump whose way to its loop passes through anything else (a timer, a
    # part of the screen drawn inside, a routine) would leave that thing half done, and a walk of a
    # pool is stepped its own way on some consoles, where a jump has no place to go. A program that
    # holds such a jump is not one a build can be made from (#refuse_stray_jumps!), so every lowering
    # can take a jump to be its innermost loop's, met while it writes that loop's body.
    module LoopJumps
      KINDS = %i[break_repeat next_repeat].freeze

      module_function

      def jump?(node) = KINDS.include?(node.kind)

      # The jumps among +statements+ and under their tests that leave them for a loop outside them:
      # not those of a `repeat` among them, which are that loop's own.
      def escaping(statements)
        statements.flat_map do |node|
          next [node] if jump?(node)
          next [] unless node.kind == :if

          escaping(node.children) + escaping(node.else&.children || [])
        end
      end

      # Whether +node+ holds a jump out of itself, to a loop around it: such a statement cannot be
      # moved away from that loop (Backends::RoutineCuts).
      def escapes?(node) = escaping([node]).any?

      # Whether +repeat+'s own body holds a `next`, which leaves out the rest of a turn: a turn's last
      # statement then does not run on every turn (Backends::LoopForm#counted_while).
      def next_in?(repeat) = escaping(repeat.children).any? { |jump| jump.kind == :next_repeat }

      # Whether +repeat+'s own body holds any jump.
      def jumps_in?(repeat) = escaping(repeat.children).any?

      # Every jump in +program+ belongs to a `repeat` that is not a walk of a pool, reached through
      # tests alone; one that does not is refused.
      def refuse_stray_jumps!(program)
        owned = Set.new.compare_by_identity
        jumps = []
        program.walk do |node|
          jumps << node if jump?(node)
          owned.merge(escaping(node.children)) if node.kind == :repeat && node.pool_walk.nil?
        end
        stray = jumps.find { |jump| !owned.include?(jump) }
        return unless stray

        raise InvariantError, "a #{stray.kind} must be inside a repeat, under tests alone, and not in a walk of a pool"
      end
    end
  end
end
