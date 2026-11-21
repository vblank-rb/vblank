# frozen_string_literal: true

# Author text is published on the website, where a paragraph that opens with words in capitals
# ("THE GAME HOLDS HANDLES. ...") reads as shouting. A lead-in to several paragraphs is a Markdown
# subheading (### or lower), a lead-in to one paragraph is its plain first sentence, and one to
# engineer material goes behind `#--` where capitals may stay. `include ShoutingParagraphs` in a
# test of doc comments.
module ShoutingParagraphs
  # The line that opens the part RDoc leaves out, and the one that closes it.
  ENGINEER_NOTES_START = /\A--\s*\z/
  ENGINEER_NOTES_END = /\A\+\+\s*\z/

  # Two or more words in capitals at the start of a paragraph.
  SHOUTING_OPENING = /\A(?:[A-Z][A-Z0-9'-]+[ ,]+(?:[A-Z][A-Z0-9'-]+|A|I)|A[ ,]+[A-Z][A-Z0-9'-]{3,})\b/

  # The paragraphs of +lines+ (comment text without its `#`) that shout, outside code fences and
  # outside `#--` ... `#++`, each as "where): the opening words".
  private def shouting_paragraphs(where, lines)
    fenced = false
    engineer = false
    paragraph_open = true
    found = []
    lines.each do |line|
      engineer = true if line.match?(ENGINEER_NOTES_START)
      engineer = false if line.match?(ENGINEER_NOTES_END)
      next if engineer

      fenced = !fenced if line.lstrip.start_with?("```")
      if line.strip.empty?
        paragraph_open = true
      elsif paragraph_open && !fenced && line.match?(SHOUTING_OPENING)
        found << "#{where}): #{line[0, 50]}"
        paragraph_open = false
      else
        paragraph_open = false
      end
    end
    found
  end
end
