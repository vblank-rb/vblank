# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# Every verb has a doc comment written for the game author, because the website's reference is
# generated from those comments (with RDoc). The comment opens with text for the author; what is
# for VBlank's engineers goes between `#--` and `#++`, which RDoc leaves out. A verb with no
# comment, or one that opens with `#--` and so has nothing for an author, fails here, naming the
# verb and where it is written.
class TestVerbDocComments < Minitest::Test
  include DslVerbs

  # The verbs whose comment is still to be written for an author. Each is taken off this list in the
  # commit that documents it, and a verb on the list that is documented fails the test until it is.
  # A verb made from source text or by `alias` has no `def` to carry a comment: it is documented
  # with a `# :method: name` comment, which RDoc reads and DslVerbs finds (see Builder::Variables).
  VERBS_AWAITING_DOCS = %i[].freeze

  # The line that opens the part RDoc leaves out.
  ENGINEER_NOTES_START = /\A--\s*\z/

  def test_every_verb_has_text_for_a_game_author
    problems = verb_problems
    undocumented = problems.keys - VERBS_AWAITING_DOCS

    assert_empty undocumented, <<~MSG
      These DSL verbs have no doc comment written for a game author. Write one above the verb's
      `def`: what the verb does, in plain words, then its options as a list and an example. Notes for
      VBlank's engineers go after a line holding only `#--`.
        #{undocumented.map { |verb| problems.fetch(verb) }.join("\n  ")}
    MSG
  end

  def test_a_verb_that_has_its_doc_comment_is_off_the_awaiting_list
    documented = VERBS_AWAITING_DOCS - verb_problems.keys

    assert_empty documented, "These verbs have a doc comment now. Remove them from VERBS_AWAITING_DOCS: #{documented.join(', ')}"
  end

  def test_the_awaiting_list_names_only_verbs
    assert_empty VERBS_AWAITING_DOCS - dsl_verbs, "These are not DSL verbs (any more): #{(VERBS_AWAITING_DOCS - dsl_verbs).join(', ')}"
  end

  # Verb => what is wrong, with the file and line to open, for each verb that has a problem.
  private def verb_problems
    dsl_verb_definitions.each_with_object({}) do |(verb, definition), found|
      problem = problem_with(verb, definition)
      found[verb] = problem if problem
    end
  end

  private def problem_with(verb, definition)
    return "#{verb}: not written with `def`, so it has no doc comment to read" unless definition

    where = "#{definition.file.delete_prefix("#{VBlank.root}/")}:#{definition.line}"
    return "#{verb} (#{where}): no doc comment" if definition.comment.empty?

    author_text = definition.comment.take_while { |line| !line.match?(ENGINEER_NOTES_START) }
    "#{verb} (#{where}): no text for the author before `#--`" if author_text.all? { |line| line.strip.empty? }
  end
end
