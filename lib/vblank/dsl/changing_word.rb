# frozen_string_literal: true

module VBlank
  module DSL
    # The sentences a refusal says when a game writes a verb the library keeps for itself, or a
    # low-level test where plain Ruby does the same.
    #
    # They live in one place because the wording and the advice under it are one promise to the
    # reader: the same slip reads the same way wherever it is written.
    module ChangingWord # :nodoc:
      module_function

      # A word the library keeps for itself. A game writes these in plain Ruby.
      def old_verb_refusal(word, at: "")
        "A game does not need `#{word}`. To fix this, change the variable with plain Ruby: " \
          "`hp = 5`, `hp += 1`, `hp -= 1`.#{at}"
      end

      # A low-level test (`if_gt :score, 5`), and +plain_if+, the plain Ruby `if` that does the same.
      def low_level_test_refusal(word, plain_if, at: "")
        "A game does not need `#{word}`. To fix this, write `#{plain_if}` and put the block's lines " \
          "under it, with `end` after them.#{at}"
      end

      # An operand as the author would write it: a variable by its own name, a number as itself.
      # Nil for anything else, which has no name to be written by.
      def as_source_text(operand)
        case operand
        when nil then nil
        when Symbol then operand.to_s
        when Numeric then operand.inspect
        when String then operand
        else operand.name&.to_s if operand.respond_to?(:name)
        end
      end
    end
  end
end
