# frozen_string_literal: true

require "test_helper"
require "published_comments"
require "author_text_checks"

# Every check a build can run has a class comment written for the game author, because the website
# publishes a page of every build error and warning from those comments, searchable by a message
# pasted into it. The comment opens with text for the author: when the check speaks, why it matters,
# the message's fixed words quoted as a `> ` line (a placeholder such as `<name>` where the message
# fills one in), and how to fix it. What is for VBlank's engineers goes between `#--` and `#++`,
# which RDoc leaves off the page.
#
# The checks are read from where a build finds them (PublishedComments.check_classes), never from a
# list kept here.
class TestCheckDocComments < Minitest::Test
  include AuthorTextChecks
  include PublishedComments

  CHECK_CLASSES = PublishedComments.check_classes

  # Words of the engineers' that mean nothing to a game author, refused in the author's text outside
  # code. A class name is two words run together, each with a capital (`FadeNeverLifted`); the names
  # of consoles and languages written that way are not internals.
  INTERNAL_WORDS = [
    /\bIR\b/, /\bnodes?\b/i, /\bdetect/i, /::/, /\w#\w/, /(?<![#\w])#[a-z_]+/,
    /\b(?!(?:PlayStation|JavaScript|SuperNintendo)\b)[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b/,
  ].freeze

  def test_there_are_checks_to_read
    assert_operator CHECK_CLASSES.length, :>=, 60, "Fewer checks than expected were found: #{CHECK_CLASSES.map(&:name)}"
  end

  def test_every_check_has_text_for_a_game_author
    missing = CHECK_CLASSES.filter_map do |klass|
      where, lines = check_comment(klass)
      "#{where}): no text for the author before `#--`" if author_lines(lines).empty?
    end

    assert_empty missing, <<~MSG
      These checks have no class comment written for a game author. Write one above the class: when
      the check speaks and why it matters, the message quoted on a `> ` line, and how to fix it.
      Notes for VBlank's engineers go after a line holding only `#--`.
        #{missing.join("\n  ")}
    MSG
  end

  def test_every_check_quotes_its_message
    unquoted = CHECK_CLASSES.filter_map do |klass|
      where, lines = check_comment(klass)
      "#{where})" unless author_lines(lines).any? { |line, _| line.start_with?("> ") }
    end

    assert_empty unquoted, <<~MSG
      These checks' author text quotes no message. Quote the message's fixed words on a line that
      starts with `> `, with a placeholder such as <name> where the message fills one in, so a search
      for a pasted message finds the page.
        #{unquoted.join("\n  ")}
    MSG
  end

  def test_no_author_text_names_internals
    named = CHECK_CLASSES.flat_map do |klass|
      where, lines = check_comment(klass)
      author_lines(lines).filter_map do |line, _|
        prose = line.gsub(/`[^`]*`/, "")
        word = INTERNAL_WORDS.lazy.filter_map { |pattern| prose[pattern] }.first
        "#{where}): #{word.inspect} in #{line[0, 60]}" if word
      end
    end

    assert_empty named, <<~MSG
      These lines of author text name the library's internals. Say what the game does in plain words,
      put game code in backticks, or move the line behind `#--`.
        #{named.join("\n  ")}
    MSG
  end

  def test_no_author_paragraph_opens_in_capitals
    shouted = CHECK_CLASSES.flat_map { |klass| shouting_paragraphs(*check_comment(klass)) }

    assert_empty shouted, "These paragraphs of author text open with words in capitals:\n  #{shouted.join("\n  ")}"
  end

  def test_no_author_paragraph_opens_with_an_ellipsis
    fragments = CHECK_CLASSES.flat_map { |klass| fragment_paragraphs(*check_comment(klass)) }

    assert_empty fragments, "These paragraphs of author text open with an ellipsis:\n  #{fragments.join("\n  ")}"
  end

  def test_no_author_line_is_a_heading_above_the_third_level
    headings = CHECK_CLASSES.flat_map { |klass| big_heading_lines(*check_comment(klass)) }

    assert_empty headings, "These lines of author text are a first- or second-level heading:\n  #{headings.join("\n  ")}"
  end
end
