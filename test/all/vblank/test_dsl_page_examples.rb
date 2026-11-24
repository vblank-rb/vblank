# frozen_string_literal: true

require "test_helper"
require "all/vblank/test_plain_ruby_guide"

# The pages under .claude/dsl/ that tell what plain Ruby builds show it with plain Ruby: each worked
# example is the body of a game block that builds and plays as written, as PLAIN_RUBY.md's are.
class TestDslPageExamples < Minitest::Test
  include WrittenExamples

  PAGES = %w[lists.md pools.md].freeze

  def test_every_worked_example_builds_and_plays
    problems = PAGES.flat_map do |page|
      example_problems(VBlank.root.join(".claude/dsl", page).read, page)
    end

    assert_empty problems, problems.join("\n")
  end

  def test_examples_write_no_list_or_pool_line
    PAGES.each do |page|
      examples = game_examples(VBlank.root.join(".claude/dsl", page).read)

      refute_empty examples, "#{page} has no worked example"
      examples.each do |example|
        refute_match(/^\s*(list|pool)[ (]/, example.code, "#{page}:#{example.line} writes a `list` or `pool` line")
      end
    end
  end
end
