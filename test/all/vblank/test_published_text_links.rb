# frozen_string_literal: true

require "test_helper"
require "published_comments"
require "author_text_checks"

# The docs site publishes the consoles' answers, the checks' class comments and the verbs' doc
# comments, and never links the repository's `.claude/` folder (the engineers' notes). A path into
# it in published text sends a reader nowhere. Text between `#--` and `#++` is not published, so it
# may name the folder.
class TestPublishedTextLinks < Minitest::Test
  include DslVerbs
  include AuthorTextChecks
  include PublishedComments

  NOTES_FOLDER = %r{\.claude/}

  ANSWER_TABLES = [
    VBlank::Console::AdvanceAnswers, VBlank::Console::ColorAnswers, VBlank::Console::SNESAnswers,
    VBlank::Console::GenesisAnswers, VBlank::Console::PS1Answers
  ].freeze

  CHECK_CLASSES = PublishedComments.check_classes

  def test_no_console_answer_names_the_notes_folder
    found = ANSWER_TABLES.flat_map do |table|
      plain = [["#{table.name}::PLAIN", table::PLAIN]]
      answers = table::ANSWERS.map { |verb, answer| ["#{table.name} #{verb}", answer.words] }
      (plain + answers).select { |_, words| words.match?(NOTES_FOLDER) }.map { |where, words| "#{where}: #{words[0, 70]}" }
    end

    assert_empty found, "These console answers point at the notes folder. Say what is meant in words:\n  #{found.join("\n  ")}"
  end

  def test_no_check_comment_names_the_notes_folder
    found = CHECK_CLASSES.flat_map { |klass| lines_naming_notes_folder(*check_comment(klass)) }

    assert_empty found, "These check comments point at the notes folder:\n  #{found.join("\n  ")}"
  end

  def test_no_verb_or_group_comment_names_the_notes_folder
    found = (verb_comments + group_comments).flat_map { |where, lines| lines_naming_notes_folder(where, lines) }

    assert_empty found, "These verb and group comments point at the notes folder:\n  #{found.join("\n  ")}"
  end

  private def lines_naming_notes_folder(where, lines)
    author_lines(lines).map(&:first).select { |line| line.match?(NOTES_FOLDER) }.map { |line| "#{where}): #{line[0, 70]}" }
  end
end
