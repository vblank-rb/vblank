# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# Keeps the DSL reference honest. It is a tree: .claude/rules/dsl-reference.md, a short map that
# every session loads, naming each page under .claude/dsl/; and each page, read only when it is
# wanted, which opens with an "On this page" list of a line per verb and then tells each in full.
# This walks the DSL verbs actually mixed into Builder right now and fails if any is on no page's
# list or is not told on its page, and if a page is missing from the map — the failure names what
# is missing and says how to fix it. A crude but effective coverage check (it looks for the verb
# name as a word; it doesn't police the signature).
class TestDslReference < Minitest::Test
  MAP = VBlank.root.join(".claude/rules/dsl-reference.md").to_s
  PAGES = VBlank.root.join(".claude/dsl").to_s

  # The map is loaded into every session and names pages, not verbs. The index it replaced held
  # a line per verb and was capped at 12,000 characters; the map is a few words a page.
  MOST_MAP_CHARACTERS = 5_000

  include DslVerbs

  # Match the verb name as a whole word (so `set` isn't satisfied by `set_cell`).
  private def mentions?(text, verb) = text.match?(/(?<!\w)#{Regexp.escape(verb.to_s)}(?!\w)/)

  # Each page with its "On this page" list and the rest of the page after it, as
  # [file name, list, rest]. A page with no list (a console's, plain-ruby.md) has an empty one.
  private def pages
    Dir.glob(File.join(PAGES, "*.md")).map do |path|
      text = File.read(path)
      list = text[/^## On this page\n(.*?)(?=^## )/m, 1].to_s
      [File.basename(path), list, list.empty? ? text : text.sub(/^## On this page\n.*?(?=^## )/m, "")]
    end
  end

  def test_every_dsl_verb_is_on_a_pages_list
    # Guard against a broken enumeration silently passing this test (empty concerns
    # would leave only list/entry, which are trivially present).
    assert_operator dsl_verbs.length, :>, 40, "DSL verb enumeration looks broken (#{dsl_verbs.length} verbs)"

    lists = pages.map { |_, list, _| list }.join("\n")
    missing = dsl_verbs.reject { |verb| mentions?(lists, verb) }
    assert_empty missing, <<~MSG
      These DSL verbs are on no page's "On this page" list under .claude/dsl/:
        #{missing.join(', ')}
      Add a line for each to the list of the page it belongs on (a short signature and what it
      does in a sentence), and tell it in full below the list — or, if it isn't really an
      authoring verb, add it to SKIP in test/dsl_verbs.rb with a note why.
    MSG
  end

  def test_every_page_is_on_the_map_and_every_page_on_the_map_is_there
    map = File.read(MAP)
    unmapped = pages.map(&:first).reject { |name| map.include?("`#{name}`") }
    assert_empty unmapped, "These pages under .claude/dsl/ are not on .claude/rules/dsl-reference.md: #{unmapped.join(', ')}"

    named = map.scan(/`([\w-]+\.md)`/).flatten.uniq
    absent = named.reject { |name| File.exist?(File.join(PAGES, name)) }
    assert_empty absent, "The map names pages that are not under .claude/dsl/: #{absent.join(', ')}"
  end

  # A verb on a page's list has to be told on that page, below the list, and not merely listed.
  def test_every_verb_on_a_list_is_told_in_full_on_its_page
    missing = pages.flat_map do |name, list, rest|
      dsl_verbs.select { |verb| mentions?(list, verb) && !mentions?(rest, verb) }.map { |verb| "#{verb} (#{name})" }
    end

    assert_empty missing, <<~MSG
      These DSL verbs are on a page's list but not told below it on that page:
        #{missing.join(', ')}
      Tell each one in full on that page, or move its line to the page it belongs on.
    MSG
  end

  def test_the_map_stays_short_enough_to_load_every_session
    size = File.read(MAP).length
    assert_operator size, :<=, MOST_MAP_CHARACTERS, <<~MSG
      .claude/rules/dsl-reference.md is #{size} characters, over #{MOST_MAP_CHARACTERS}. Every
      session loads it, so it names pages in a few words each; a verb's line goes on its page.
    MSG
  end
end
