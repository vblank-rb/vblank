# frozen_string_literal: true

require "test_helper"
require "shouting_paragraphs"

# The comment atop each file of examples/ is published as that example's page on the website: its
# first line is the title and a summary split at " — ", and the rest is the page's text. So the
# first line has a title and a summary, and no paragraph of the text opens with words in capitals
# (ShoutingParagraphs says what to do about one).
class TestExampleHeaders < Minitest::Test
  include ShoutingParagraphs

  EXAMPLES = Dir.glob(VBlank.root.join("examples/*.rb").to_s).sort.freeze

  # The comment lines atop +file+ (without their `#`), after the shebang and the magic comment.
  private def header_of(file)
    lines = File.readlines(file).map(&:chomp)
    lines = lines.drop_while { |line| line.start_with?("#!", "# frozen_string_literal") || line.strip.empty? }
    lines.take_while { |line| line.start_with?("#") }.map { |line| line.sub(/\A# ?/, "") }
  end

  private def relative(file) = file.delete_prefix("#{VBlank.root}/")

  def test_every_example_has_a_comment_atop_it
    bare = EXAMPLES.select { |file| header_of(file).empty? }.map { |file| relative(file) }

    assert_empty bare, "These examples have no comment atop them, which is their page on the website: #{bare.join(', ')}"
  end

  def test_the_first_line_is_a_title_and_a_summary_split_at_a_dash
    wrong = EXAMPLES.filter_map do |file|
      first = header_of(file).first
      next if first.nil? || first.match?(/\A[^—]+ — \S/) && !first.match?(SHOUTING_OPENING)

      "#{relative(file)}: #{first.to_s[0, 60]}"
    end

    assert_empty wrong, <<~MSG
      The first line of an example's header is its title and a summary, split at " — ", and the
      title is not in capitals:
        #{wrong.join("\n  ")}
    MSG
  end

  def test_no_paragraph_of_a_header_opens_in_capitals
    shouted = EXAMPLES.flat_map { |file| shouting_paragraphs(relative(file), header_of(file).drop(1)) }

    assert_empty shouted, <<~MSG
      These paragraphs of example headers open with words in capitals. Make a lead-in to several
      paragraphs a `###` subheading, a lead-in to one paragraph its plain first sentence, or move
      the paragraph behind `#--` where capitals may stay.
        #{shouted.join("\n  ")}
    MSG
  end
end
