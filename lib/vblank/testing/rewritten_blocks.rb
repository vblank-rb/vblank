# frozen_string_literal: true

module VBlank
  module Testing
    # A test's game block is run through DSL::PlainRuby as a game's is, so a test can write what it
    # means in normal Ruby. A test starts its game on a Builder by hand, with `instance_eval`, and
    # a helper runs the rest a test hands it with `instance_exec`, so those two are the places
    # every such block passes. The checks stay out: a test names its own helpers and fixtures, and
    # a game has no reason to. The library's own blocks are left as a game would run them.
    module RewrittenBlocks
      def instance_eval(*given, &block)
        refuse_shareable_test_block!(block) if given.empty?
        return super unless given.empty? && test_block?(block)

        super(&DSL::PlainRuby.rewrite(block, checked: false))
      end

      def instance_exec(*given, &block)
        refuse_shareable_test_block!(block)
        return super unless test_block?(block)

        super(*given, &DSL::PlainRuby.rewrite(block, checked: false))
      end

      # A test's block kept in a constant is shareable (InRactors), and cannot be rewritten.
      private def refuse_shareable_test_block!(block)
        DSL::PlainRuby.refuse_shareable_block_with_game_code!(block) if block && !library_block?(block)
      end

      private def test_block?(block) = block && DSL::PlainRuby.rewritable?(block) && !library_block?(block)

      private def library_block?(block)
        block.source_location&.first.to_s.start_with?(DSL::PlainRuby::BlockChecks.library_folder)
      end
    end

    # A test's own game names its helpers and fixtures, so its checks stay out here too.
    module UncheckedGameBlocks
      def game_blocks_checked? = false
    end
  end
end

VBlank::Builder.prepend(VBlank::Testing::RewrittenBlocks)
VBlank::DSL::PlainRuby.singleton_class.prepend(VBlank::Testing::UncheckedGameBlocks)
