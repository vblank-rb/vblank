# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHEN A SPRITE SHOWS, as tests: +tests+ are comparisons that must all hold, and +flag+ a value
      # that must be 1, or nil. For the Genesis's and the Color's placing of a sprite.
      #
      # A sprite shows while its `active` is 1. The builder makes that a PRODUCT for a sprite that
      # belongs to a scene, or is declared under an `if`, or is a place of a pool: its own flag times
      # "is this the scene that is up", times each condition it was written under
      # (Builder#gated_by_scene), and a pool's place is "the pool holds more things than this place's
      # rank" (DSL::Pool#rank_taken). A comparison is 0 or 1, so the product is 1 exactly when every
      # comparison holds and what is left is 1, which is a compare and a branch each. Worked out as
      # written it is a multiply of two whole numbers for every such sprite on every pass, and then a
      # compare of the answer with 1: a sprite that does not show costs most of what one that shows
      # does, so a game of many sprites declared and few showing pays for every one.
      ShownWhen = Data.define(:tests, :flag) do
        # +active+ as tests, or nil where it is not a product of comparisons and at most one value
        # besides, each changing nothing by being worked out or left out (IR::Unchanging): the tests
        # stop at the first that fails. The block returns whether a part is a number the lowering
        # already knows.
        def self.of(active, &known)
          factors = factors_of(active)
          tests, flags = factors.partition { |factor| comparison?(factor) }
          return unless flags.length <= 1
          return unless factors.all? { |factor| Unchanging.value?(factor, &known) }

          new(tests: tests, flag: flags.first)
        end

        def self.factors_of(node) = product?(node) ? factors_of(node.lhs) + factors_of(node.rhs) : [node]

        def self.product?(node) = node.is_a?(Node) && node.kind == :binop && node.op == :*

        def self.comparison?(node) = node.is_a?(Node) && node.kind == :binop && COMPARISON_OPERATORS.include?(node.op)

        COMPARISON_OPERATORS = %i[< <= > >= == !=].freeze
      end
    end
  end
end
