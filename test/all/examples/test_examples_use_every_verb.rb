# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"
require "prism"

# THE GOLDEN PATH SEES WHAT THE EXAMPLES SHOW (test_every_example_plays.rb), so a verb no example
# calls is a verb a day's testing never builds. Each verb is held to a call in one.
#
# A call is what Ruby's own parser (Prism) reads as one, on any receiver: `fade :black, 50`,
# `build.fade`, `ball_dx.flip!`. A word in a comment or a string, a symbol (`plays: :noise`), a
# keyword (`after: :eighth`) and a local variable of the same name (`|part|`) are not calls, so
# none of them counts.
class TestExamplesUseEveryVerb < Minitest::Test
  include DslVerbs

  # The flat spellings of what a variable's own handle does (`set :x, 5`, `flip :dx`, `add :x, 1`):
  # each exists only to refuse with a friendly error naming the word to write instead, so an
  # example calling one would not build. Builder::Variables makes them, from these lists.
  FLAT_REFUSALS = (VBlank::Builder::Variables::CHANGING_HANDLE_WORDS.keys +
                   VBlank::Builder::Variables::CHANGING_OPERATOR_WORDS.keys + %i[set copy]).freeze

  # What a game has no reason to show, besides those: tools for finding a fault.
  # `entry` is raw ARM for the Advance's processor, refused by every other console's build; a game
  # reaches for it only for what the verbs cannot say, and an example is for what they can.
  # `built_for_computer?` is a Ruby true or false read while the game is built and makes nothing
  # of its own, so an example naming it would give the golden path nothing more to build.
  # data_pack reads the player's copy of a retail original, which no example can ship; its own
  # tests make an original up. shell_screen is the first screen of a shell, a port built with its
  # data pack left out, so it needs one too.
  # colors_name_of gives the name of the list a picture is drawn from, which a game needs only
  # for a pose that takes its colours from a data pack's frame; elsewhere the game wrote the name.
  NOT_FOR_AN_EXAMPLE = (%i[debug_halt dump_func entry data_pack shell_screen colors_name_of built_for_computer?] +
                        FLAT_REFUSALS).uniq.freeze

  def test_every_verb_is_called_in_an_example
    called = Dir[VBlank.root.join("examples/**/*.rb").to_s].each_with_object(Set.new) do |path, names|
      names.merge(called_names(File.read(path)))
    end
    missing = (dsl_verbs - NOT_FOR_AN_EXAMPLE).reject { |verb| called.include?(verb) }

    assert_empty missing, "No example calls these verbs, so the golden path never builds them. " \
                          "Call each in an example, or say why not in NOT_FOR_AN_EXAMPLE."
  end

  def test_what_is_left_out_is_still_a_verb
    assert_empty NOT_FOR_AN_EXAMPLE - dsl_verbs
  end

  def test_a_call_counts_on_any_receiver
    assert_includes called_names("fade :black, 50"), :fade
    assert_includes called_names("build.fade :black, 50"), :fade
    assert_includes called_names("ball_dx.flip!"), :flip!
    assert_includes called_names("if lives <= 0\n  start_over :play\nend"), :start_over
  end

  def test_a_word_that_is_not_a_call_does_not_count
    source = <<~RUBY
      # tint the screen, then fade it
      draw_text "fade", 0, 0, :white
      voice :drums, plays: :noise
      v.vibrato after: :eighth
      parts.map { |part| part * 2 }
    RUBY
    names = called_names(source)

    %i[tint fade noise after part].each { |word| refute_includes names, word }
  end

  # Every method name the Ruby +source+ calls.
  private def called_names(source)
    names = Set.new
    pending = [Prism.parse(source).value]
    while (node = pending.pop)
      names << node.name if node.is_a?(Prism::CallNode)
      pending.concat(node.compact_child_nodes)
    end
    names
  end
end
