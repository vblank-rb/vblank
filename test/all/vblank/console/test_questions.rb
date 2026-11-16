# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A PROGRAM'S OWN SETTINGS ASK OF A CONSOLE (Console::Questions#program_question), asked of
# every console's build at once, as test_refused_verbs.rb asks each refused verb.
class TestQuestions < Minitest::Test
  # Every console's build but the Genesis's writes the main volume to its sound chip
  # (test/main_volume_tests.rb). The Genesis's chips have none, so its build refuses a game that
  # names one, rather than play it at another loudness.
  def test_a_main_volume_is_refused_by_a_console_without_one
    consoles = VBlank::Console.kits.map(&:name).reject { |console| VBlank::Console.described(console).sets_main_volume }
    assert_equal [:genesis], consoles

    printed = StringIO.new
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("MAINVOL", console: :genesis, out: StringIO.new, err: printed) do
        enable_sound main_volume: 96
        game_loop { nil }
      end
    end
    assert_match(/main volume/, "#{printed.string} #{error.message}")
  end
end
