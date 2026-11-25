# frozen_string_literal: true

require "test_helper"
require "published_comments"
require "author_text_checks"

# The handles a game holds (a Value, a Sprite, a Pool, what each verb hands back) are published on
# the website as pages of their own, generated from their doc comments with RDoc. Each class comment
# is that page, its first line the title; each public method's comment is the method's entry. Both
# open with text for a game author, and notes for VBlank's engineers go between `#--` and `#++`,
# which RDoc leaves out.
#
# Every class, module and `Data.define` constant in lib/vblank/dsl is a handle unless its line
# carries RDoc's `# :nodoc:`, which leaves it, and everything inside it, off the website. A public
# method is held to the same rule: one that exists only for the library to call is marked `# :nodoc:`
# on its `def` line.
class TestHandleDocComments < Minitest::Test
  include DslVerbs
  include AuthorTextChecks
  include PublishedComments

  HANDLES = PublishedComments.handles

  # The longest a page title reads well in the website's sidebar.
  TITLE_LENGTH_LIMIT = 60

  def test_handles_are_found
    names = HANDLES.map(&:name)

    %w[VBlank::DSL::Value VBlank::DSL::Sprite VBlank::DSL::Pool VBlank::DSL::List].each do |name|
      assert_includes names, name
    end
  end

  def test_every_handle_has_a_page_for_a_game_author
    missing = HANDLES.reject { |handle| author_text?(handle.comment) }
                     .map { |handle| "#{handle.name} (#{relative_path(handle.file)}:#{handle.line})" }

    assert_empty missing, <<~MSG
      These handles have no class comment written for a game author. Write one above the `class`:
      a title on the first line, then what a game does with it. If a game never holds one, mark the
      `class` line `# :nodoc:`.
        #{missing.join("\n  ")}
    MSG
  end

  def test_every_handle_page_opens_with_a_title
    untitled = HANDLES.select { |handle| author_text?(handle.comment) }.filter_map do |handle|
      title = handle.comment.first.to_s.strip
      next if title.length <= TITLE_LENGTH_LIMIT && !title.end_with?(".") && handle.comment[1].to_s.strip.empty?

      "#{handle.name} (#{relative_path(handle.file)}:#{handle.line}): #{title[0, 60]}"
    end

    assert_empty untitled, <<~MSG
      These handle pages do not open with a title. Make the first line a short name with no full
      stop (Sprites the console draws, not a sentence), then a blank comment line.
        #{untitled.join("\n  ")}
    MSG
  end

  def test_every_public_handle_method_has_text_for_a_game_author
    missing = HANDLES.flat_map do |handle|
      PublishedComments.handle_methods(handle).filter_map do |where, comment|
        next "#{where}): not written with `def`, so it has no comment to read" if comment.nil?
        next "#{where}): no doc comment" if comment.empty?

        "#{where}): no text for the author before `#--`" unless author_text?(comment)
      end
    end

    assert_empty missing, <<~MSG
      These public handle methods have no doc comment written for a game author. Write one above the
      `def`: what it does, in plain words, its options as a list and an example. If only the library
      calls it, mark its `def` line `# :nodoc:`.
        #{missing.join("\n  ")}
    MSG
  end

  def test_no_handle_paragraph_opens_in_capitals
    shouted = handle_comments.flat_map { |where, lines| shouting_paragraphs(where, lines) }

    assert_empty shouted, <<~MSG
      These paragraphs of handle text open with words in capitals. Make a lead-in to several
      paragraphs a `###` subheading, a lead-in to one paragraph its plain first sentence, or move
      the paragraph behind `#--`.
        #{shouted.join("\n  ")}
    MSG
  end

  def test_no_handle_paragraph_opens_with_an_ellipsis
    fragments = handle_comments.flat_map { |where, lines| fragment_paragraphs(where, lines) }

    assert_empty fragments, "These paragraphs of handle text open with an ellipsis. Write the sentence whole:\n  " \
                            "#{fragments.join("\n  ")}"
  end

  def test_no_handle_line_is_a_heading_above_the_third_level
    headings = handle_comments.flat_map { |where, lines| big_heading_lines(where, lines) }

    assert_empty headings, <<~MSG
      These lines of handle text render as a first- or second-level heading. Fence an example in
      ```ruby so its comments stay code, and write a heading as ### or lower.
        #{headings.join("\n  ")}
    MSG
  end

  private def author_text?(comment)
    comment.take_while { |line| !line.match?(ENGINEER_NOTES_START) }.any? { |line| !line.strip.empty? }
  end
end
