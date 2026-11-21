# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"
require "author_text_checks"

# The docs site publishes the consoles' answers, the checks' class comments and the verbs' doc
# comments, and never links the repository's `.claude/` folder (the engineers' notes). A path into
# it in published text sends a reader nowhere. Text between `#--` and `#++` is not published, so it
# may name the folder.
class TestPublishedTextLinks < Minitest::Test
  include DslVerbs
  include AuthorTextChecks

  Guardrails = VBlank::IR::Guardrails
  NOTES_FOLDER = %r{\.claude/}

  ANSWER_TABLES = [
    VBlank::Console::AdvanceAnswers, VBlank::Console::ColorAnswers, VBlank::Console::SNESAnswers,
    VBlank::Console::GenesisAnswers, VBlank::Console::PS1Answers
  ].freeze

  def test_no_console_answer_names_the_notes_folder
    found = ANSWER_TABLES.flat_map do |table|
      plain = [["#{table.name}::PLAIN", table::PLAIN]]
      answers = table::ANSWERS.map { |verb, answer| ["#{table.name} #{verb}", answer.words] }
      (plain + answers).select { |_, words| words.match?(NOTES_FOLDER) }.map { |where, words| "#{where}: #{words[0, 70]}" }
    end

    assert_empty found, "These console answers point at the notes folder. Say what is meant in words:\n  #{found.join("\n  ")}"
  end

  def test_no_check_comment_names_the_notes_folder
    found = check_comments.flat_map { |where, lines| lines_naming_notes_folder(where, lines) }

    assert_empty found, "These check comments point at the notes folder:\n  #{found.join("\n  ")}"
  end

  def test_no_verb_or_group_comment_names_the_notes_folder
    found = verb_and_group_comments.flat_map { |where, lines| lines_naming_notes_folder(where, lines) }

    assert_empty found, "These verb and group comments point at the notes folder:\n  #{found.join("\n  ")}"
  end

  private def lines_naming_notes_folder(where, lines)
    author_lines(lines).map(&:first).select { |line| line.match?(NOTES_FOLDER) }.map { |line| "#{where}): #{line[0, 70]}" }
  end

  # Read as test_check_doc_comments.rb reads them: every class in Guardrails::Checks and each check
  # an effect pack brings.
  private def check_comments
    in_module = Guardrails::Checks.constants.map { |name| Guardrails::Checks.const_get(name) }
                                  .select { |value| value.is_a?(Class) && value.method_defined?(:detect) }
    from_packs = VBlank::Effects::DEFAULT_PACKS.flat_map { |pack| pack.respond_to?(:checks) ? Array(pack.checks) : [] }
    classes = (in_module + (Guardrails.default_checks + from_packs).map(&:class)).uniq
    classes.filter_map do |klass|
      file, line = Object.const_source_location(klass.name)
      found = DslVerbs.container_comments(file).find { |_, at, _| at == line }
      ["#{klass.name} (#{file.delete_prefix("#{VBlank.root}/")}:#{line}", found.last] if found
    end
  end

  private def verb_and_group_comments
    verbs = dsl_verb_definitions.filter_map do |verb, definition|
      ["#{verb} (#{definition.file.delete_prefix("#{VBlank.root}/")}:#{definition.line}", definition.comment] if definition
    end
    files = Dir.glob(VBlank.root.join("lib/vblank/builder/*.rb").to_s) + [VBlank.root.join("lib/vblank/builder.rb").to_s] +
            Dir.glob(VBlank.root.join("lib/vblank/effects/packs/*.rb").to_s)
    groups = files.sort.flat_map do |file|
      DslVerbs.container_comments(file).map { |name, line, lines| ["#{name} (#{file.delete_prefix("#{VBlank.root}/")}:#{line}", lines] }
    end
    verbs + groups
  end
end
