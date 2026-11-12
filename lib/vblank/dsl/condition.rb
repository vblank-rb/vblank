# frozen_string_literal: true

module VBlank
  module DSL
    # The result of comparing two Values: a yes/no test the program branches on.
    # A game branches on one with `if` and joins two with `&&` and `||` (see PlainRuby).
    # Ruby lets nobody change what those mean, so the rewrite turns them into the calls
    # below: #open_branch for `if`, and & (both) and | (either) to combine tests.
    #
    # Code that the rewrite does not read must call those itself. There, a native `if
    # (x > 5)` looks right, but a Condition is *truthy* to Ruby, so its body would emit
    # unconditionally at build time with the comparison silently ignored — no error,
    # just a ROM that always runs the branch.
    class Condition
      Build = IR::Build

      def initialize(builder, node)
        @builder = builder
        @node = node
        @source = self.class.author_source
        # Enter the builder's "pending" set on birth; a branch or & / | take us back out
        # once we're used. Whatever never leaves was built and never branched on —
        # the fingerprint of a comparison dropped into a native `if`.
        builder.track_condition(self)
      end

      # The IR value node for the test (a comparison binop).
      attr_reader :node

      # Where the author built this Condition ("file.rb:line"), or nil if it can't be
      # pinned down — used to point the orphaned-Condition diagnostic at their code.
      attr_reader :source

      # Both tests must hold. Parenthesize the operands — `&` binds tighter than the
      # comparisons: (a > b) & (c < d).
      def &(other)
        compose(:and, other)
      end

      # Either test may hold: (a > b) | (c < d).
      def |(other)
        compose(:or, other)
      end

      # One test holds and the other does not: (a > b) ^ (c < d).
      def ^(other)
        compose(:!=, other)
      end

      def when_true(*)
        raise PlainRuby::Refused, ChangingWord.old_verb_refusal(:when_true, at: Messages::AuthorSource.at_author_line)
      end

      # Every Ruby object has `then`, which would run the block while the game is built and
      # record its body with no test around it. A test is branched on with `if`.
      def then(*)
        raise ArgumentError, "`.then` does not branch on a test. To fix this, write `if`: `if x > 5 ... end`." \
                             "#{" (at #{@source})" if @source}"
      end

      # The library's own branch on a test, for code recording statements by hand. Records an
      # `if` node carrying the block and returns a {Branch} for the other side.
      def record_branch(&block)
        @builder.consume_condition(self)
        Branch.new(@builder, @builder.record_conditional(@node, &block))
      end

      # The same branch taken a step at a time, for normal Ruby's `if` (see PlainRuby), whose
      # sides are not blocks. Statements recorded until #close_branch go in it.
      def open_branch
        @builder.consume_condition(self)
        @builder.open_branch(@node)
      end

      # ...and its other side, with the node #open_branch gave back.
      def open_other_branch(if_node) = @builder.open_other_branch(if_node)

      def close_branch = @builder.close_branch

      # Forget a branch that turned out to hold nothing.
      def take_back_branch(if_node) = @builder.take_back_branch(if_node)

      # A loop on this test, stopping once it holds, taken a step at a time as a branch is.
      # +test_statements+ are what working the test out recorded (Builder#open_repeat).
      def open_repeat(most_passes, test_statements: [])
        @builder.consume_condition(self)
        @builder.open_repeat(most_passes, @node, test_statements: test_statements)
      end

      def close_repeat = @builder.close_repeat

      def hidden_variable(why, like: nil) = @builder.hidden_variable(why, like: like)

      # The opposite test. A Ruby `!` on a Condition would otherwise answer plain false, and
      # the comparison would be lost with no word said.
      def !
        @builder.consume_condition(self)
        Condition.new(@builder, Build.binop(:==, @node, Build.int(0)))
      end

      # This test is not needed after all: a plain value beside it decided the answer
      # (see PlainRuby::Steps.join_both). Marks it used, and answers false.
      def discard!
        @builder.consume_condition(self)
        false
      end

      private

      # Build a combined Condition. Both sides must be Conditions — you compose
      # yes/no tests, not raw numbers (a bare number has no branch meaning here).
      # Both operands are folded into the new one, so both are now used.
      def compose(op, other)
        unless other.is_a?(Condition)
          raise ArgumentError,
                "compose conditions with & and |, e.g. (a > b) & (c < d) — got #{other.class}"
        end

        @builder.consume_condition(self)
        @builder.consume_condition(other)
        Condition.new(@builder, Build.binop(op, @node, other.node))
      end

      # The first call-stack frame outside the library — the author's line — as
      # "path:line", or nil if every frame is internal.
      def self.author_source = Messages::AuthorSource.author_source
    end
  end
end
