# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A PROGRAM'S OWN SETTINGS ASK OF A CONSOLE (Console::Questions#program_question), asked of
# every console's build at once, as test_refused_verbs.rb asks each refused verb.
class TestQuestions < Minitest::Test
  # The Super Nintendo's build writes the main volume to its sound chip
  # (test/lowering/snes/vblank/ir/backends/snes/test_snes_main_volume.rb). Every other console's
  # build refuses a game that names one, rather than play it at another loudness.
  def test_a_main_volume_is_refused_by_every_other_consoles_build
    (VBlank::Console.kits.map(&:name) - [:snes]).each do |console|
      printed = StringIO.new
      error = assert_raises(VBlank::BuildError, console.to_s) do
        VBlank.build("MAINVOL", console: console, out: StringIO.new, err: printed) do
          enable_sound main_volume: 96
          game_loop { nil }
        end
      end
      assert_match(/main volume/, "#{printed.string} #{error.message}", console.to_s)
    end
  end

  # A program that asks two things answers the one this console cannot do: two players on a
  # console that takes them, and a main volume it does not set.
  def test_a_main_volume_refusal_is_not_hidden_by_a_players_question
    printed = StringIO.new
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("MAINVOL", console: :ps1, players: 2, out: StringIO.new, err: printed) do
        enable_sound main_volume: 96
        game_loop { nil }
      end
    end
    assert_match(/main volume/, "#{printed.string} #{error.message}")
  end
end
