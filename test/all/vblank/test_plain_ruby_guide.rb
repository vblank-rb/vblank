# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The worked examples of a page written for game authors, each the body of a game block, built in
# a file of its own as a game is and played. PLAIN_RUBY.md's are held here, and the pages under
# .claude/dsl/ that tell what plain Ruby builds by test_dsl_page_examples.rb.
module WrittenExamples
  # One ```ruby block of a page: its code, the line of text before it, and the next plain block
  # after it, which quotes what VBlank says.
  Example = Data.define(:code, :line, :lead, :quoted)

  # Examples that show a part of a game or a file of one, not a game block's body.
  SHOWN_ONLY = [/^class /, /require_game_file/].freeze

  # Every example in +text+ that is a game block's body.
  private def game_examples(text) = ruby_examples(text).reject { |example| SHOWN_ONLY.any? { |shown| example.code.match?(shown) } }

  private def ruby_examples(page_text)
    lines = page_text.lines
    found = []
    lead = nil
    index = 0
    while index < lines.length
      text = lines[index]
      if text.start_with?("```")
        kind = text.strip.delete_prefix("```")
        start = index
        index += 1
        body = []
        while index < lines.length && !lines[index].start_with?("```")
          body << lines[index]
          index += 1
        end
        if kind == "ruby"
          found << Example.new(code: body.join, line: start + 2, lead: lead, quoted: nil)
        elsif found.last && found.last.quoted.nil? && found.last.lead == "Refused:"
          found[-1] = found.last.with(quoted: body.join.strip)
        end
      elsif !text.strip.empty?
        lead = text.strip
      end
      index += 1
    end
    found
  end

  # Builds +example+ as a game block written in a file of its own, as a game is, and plays it.
  private def build_and_play(example, folder)
    path = File.join(folder, "guide_#{example.line}.rb")
    File.write(path, "proc do\n#{example.code}end\n")
    block = RubyVM::InstructionSequence.compile_file(path).eval
    builder = VBlank::Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block))
    builder.finalize_program
    refuse_as_the_build_would!(builder)
    game_player.run(builder.program, frames: 2)
  end

  # A build also stops on what its checks find wrong once the whole program is made (`hp + 1`
  # worked out and dropped), as VBlank.build does.
  private def refuse_as_the_build_would!(builder)
    checks = VBlank::IR::Guardrails.default_checks + [VBlank::IR::Guardrails::Checks::OrphanedExpression.new(builder.expressions)]
    errors = VBlank::IR::ProgramChecks.findings_for!(builder.program, checks: checks).errors
    raise VBlank::BuildError, errors.map(&:message).join("\n") unless errors.empty?
  end

  # What is wrong with +example+, or nil.
  private def example_problem(example, folder)
    build_and_play(example, folder)
    "builds, and the page says it is refused" if example.lead == "Refused:"
  rescue StandardError => e
    return "does not build: #{e.class}: #{e.message}" unless example.lead == "Refused:"

    "is refused saying #{e.message.inspect}, not #{example.quoted.inspect}" unless e.message.include?(example.quoted.to_s)
  end

  # Each problem of the examples in +text+, as "+page+:line what is wrong".
  private def example_problems(text, page)
    Dir.mktmpdir do |folder|
      game_examples(text).filter_map do |example|
        problem = example_problem(example, folder)
        "#{page}:#{example.line} #{problem}" if problem
      end
    end
  end
end

# PLAIN_RUBY.md, the published account of plain Ruby in a game, holds to what VBlank does: each of
# its Ruby examples is the body of a game block that builds and plays, and each one shown after
# "Refused:" is refused with the words quoted after "VBlank says:". A wrong rule in the guide is
# a failing test here.
class TestPlainRubyGuide < Minitest::Test
  include WrittenExamples

  GUIDE = VBlank.root.join("PLAIN_RUBY.md").read

  def test_every_example_builds_and_every_refusal_says_what_the_guide_quotes
    problems = example_problems(GUIDE, "PLAIN_RUBY.md")

    assert_empty problems, problems.join("\n")
    assert_operator game_examples(GUIDE).length, :>, 20
  end
end
