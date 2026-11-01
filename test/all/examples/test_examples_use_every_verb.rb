# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# THE GOLDEN PATH SEES WHAT THE EXAMPLES SHOW (test_every_example_plays.rb), so a verb no example
# says is a verb a day's testing never builds. Each verb is held to appearing in one, by its word.
class TestExamplesUseEveryVerb < Minitest::Test
  include DslVerbs

  # What a game has no reason to show: tools for finding a fault, the low-level spellings of `if`,
  # and the flat spellings that exist only to refuse with a friendly error naming the new one.
  NOT_FOR_AN_EXAMPLE = %i[debug_halt dump_func
                          if_eq if_ne if_gt if_lt if_ge if_gte if_le if_lte if_held if_pressed
                          add_var sub sub_var negate].freeze

  def test_every_verb_appears_in_an_example
    written = Dir[VBlank.root.join("examples/**/*.rb").to_s].map { |path| File.read(path) }.join("\n")
    missing = (dsl_verbs - NOT_FOR_AN_EXAMPLE).reject { |verb| written.match?(/(?<!\w)#{Regexp.escape(verb)}(?![\w?!])/) }

    assert_empty missing, "These verbs appear in no example, so the golden path never builds them. " \
                          "Use each in an example, or say why not in NOT_FOR_AN_EXAMPLE."
  end

  def test_what_is_left_out_is_still_a_verb
    assert_empty NOT_FOR_AN_EXAMPLE - dsl_verbs
  end
end
