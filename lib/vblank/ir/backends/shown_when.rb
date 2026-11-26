# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # When a sprite shows, as tests: +tests+ are comparisons that must all hold, and +flag+ a value
      # that must be 1, or nil. For a cartridge lowering's placing of a sprite.
      #
      # A sprite shows while its `active` is 1. The builder makes that a product for a sprite that
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

        # +items+, the frame's placing in order, with each stretch of two or more sprites side by side
        # that belong to one scene and share tests put together as a SceneRun; every other item is
        # left as it is. The block gives a sprite's ShownWhen, or nil where it cannot be asked as
        # tests, which keeps that sprite out of any run.
        #
        # A sprite a scene owns is held to "is this scene up" (Builder#gated_by_scene), which every
        # sprite of that scene shares. Asked once for the stretch, a scene that is not up costs one
        # test however many sprites it owns, as a console's own games keep only the objects of what
        # is on screen in the list they walk each frame.
        def self.scene_runs(items, &shown_of)
          items.chunk_while { |one, next_one| scene_owned?(one) && scene_owned?(next_one) && one.scene == next_one.scene }
               .flat_map { |stretch| Array(scene_run_of(stretch, &shown_of) || stretch) }
        end

        def self.scene_owned?(item) = item.is_a?(Node) && item.kind == :object && !item.scene.nil?

        # The SceneRun +stretch+ makes, or nil where it is one sprite, or shares no test.
        def self.scene_run_of(stretch, &shown_of)
          return nil unless stretch.length >= 2 && scene_owned?(stretch.first)

          each_shown = stretch.map(&shown_of)
          return nil if each_shown.any?(&:nil?)

          shared = each_shown.first.tests.select { |test| each_shown.all? { |shown| shown.holds_test?(test) } }
          return nil if shared.empty?

          own = each_shown.map { |shown| shown.with(tests: shown.tests.reject { |test| shared.any? { |one| one.same_shape?(test) } }) }
          SceneRun.new(tests: shared, members: stretch.zip(own))
        end
        private_class_method :scene_owned?, :scene_run_of

        # Whether one of this sprite's tests reads the same as +test+.
        def holds_test?(test) = tests.any? { |own| own.same_shape?(test) }

        def self.factors_of(node) = product?(node) ? factors_of(node.lhs) + factors_of(node.rhs) : [node]

        def self.product?(node) = node.is_a?(Node) && node.kind == :binop && node.op == :*

        def self.comparison?(node) = node.is_a?(Node) && node.kind == :binop && COMPARISON_OPERATORS.include?(node.op)

        COMPARISON_OPERATORS = %i[< <= > >= == !=].freeze
      end

      # Sprites placed one after another that one scene owns (ShownWhen.scene_runs): +tests+ every
      # one of them is held to, asked once before the first, and +members+ each sprite with its
      # ShownWhen less those tests.
      SceneRun = Data.define(:tests, :members)
    end
  end
end
