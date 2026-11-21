# frozen_string_literal: true

# Author text is published on the website, so three things that read wrongly there are refused.
#
# - A paragraph that opens with words in capitals ("THE GAME HOLDS HANDLES. ...") reads as shouting.
#   A lead-in to several paragraphs is a Markdown subheading (### or lower), a lead-in to one
#   paragraph is its plain first sentence, and one to engineer material goes behind `#--`.
# - A paragraph that opens with an ellipsis ("...and the world slides left") reads as a fragment. A
#   sentence carried over from a line of code belongs in that code's fenced block, or is written whole.
# - A line that is `#` or `##` and a space, outside a ``` fence, is a heading above the verb's own
#   (each verb is a second-level heading on the website). An example is fenced, so the comments in
#   it stay code; a heading inside the text is ### or lower.
#
# Text between `#--` and `#++` is for VBlank's engineers and is left off the page, so it is not read.
# `include AuthorTextChecks` in a test of doc comments.
module AuthorTextChecks
  # The line that opens the part RDoc leaves out, and the one that closes it.
  ENGINEER_NOTES_START = /\A--\s*\z/
  ENGINEER_NOTES_END = /\A\+\+\s*\z/

  # Two or more words in capitals at the start of a paragraph.
  SHOUTING_OPENING = /\A(?:[A-Z][A-Z0-9'-]+[ ,]+(?:[A-Z][A-Z0-9'-]+|A|I)|A[ ,]+[A-Z][A-Z0-9'-]{3,})\b/

  # An ellipsis, three dots or the one character, at the start of a paragraph.
  FRAGMENT_OPENING = /\A\s*(?:\.\.\.|…)/

  # A Markdown heading of the first or second level: up to three spaces, one or two #, a space.
  BIG_HEADING = /\A {0,3}\#{1,2}(?:\s|\z)/

  # The paragraphs of +lines+ (comment text without its `#`) that shout, each as "where): the
  # opening words".
  private def shouting_paragraphs(where, lines)
    paragraph_openings(lines).select { |line| line.match?(SHOUTING_OPENING) }.map { |line| "#{where}): #{line[0, 50]}" }
  end

  # The paragraphs of +lines+ that open with an ellipsis.
  private def fragment_paragraphs(where, lines)
    paragraph_openings(lines).select { |line| line.match?(FRAGMENT_OPENING) }.map { |line| "#{where}): #{line[0, 50]}" }
  end

  # The lines of +lines+ that render as a first- or second-level heading.
  private def big_heading_lines(where, lines)
    author_lines(lines).map(&:first).select { |line| line.match?(BIG_HEADING) }.map { |line| "#{where}): #{line[0, 50]}" }
  end

  # The first line of each paragraph of author text.
  private def paragraph_openings(lines)
    author_lines(lines).select(&:last).map(&:first)
  end

  # [line, whether it opens a paragraph] for each line outside a ``` fence and outside `#--` ... `#++`.
  private def author_lines(lines)
    fenced = false
    engineer = false
    paragraph_open = true
    found = []
    lines.each do |line|
      engineer = true if line.match?(ENGINEER_NOTES_START)
      if line.match?(ENGINEER_NOTES_END)
        engineer = false
        paragraph_open = true
        next
      end
      next if engineer

      if line.lstrip.start_with?("```")
        fenced = !fenced
        paragraph_open = false
      elsif line.strip.empty?
        paragraph_open = true
      elsif !fenced
        found << [line, paragraph_open]
        paragraph_open = false
      end
    end
    found
  end
end
