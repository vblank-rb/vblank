# frozen_string_literal: true

require "test_helper"
require "palette_walk_tests"

# test/palette_walk_tests.rb on a PlayStation, whose runtime works a colour out in rt_color_walked
# (Runtime::Colors) for a screen drawn from tiles.
class TestPS1PaletteWalk < Minitest::Test
  include PaletteWalkTests

  CONSOLE = :ps1
  COLOR_ROUTINE = "rt_color_walked"

  # The PlayStation's graphics chip mixes by halves and sums, and how it fades part of the screen is
  # decided when it is made (Console::PS1Answers::UNMADE_VERBS): until then such a fade is refused as not
  # made yet, not in the words of a console without the hardware.
  def test_a_fade_of_part_of_the_screen_is_refused_in_the_answers_words
    kit = VBlank::Console.for(CONSOLE)
    PART_OF_THE_SCREEN.each do |where|
      error = assert_raises(VBlank::IR::Backends::NotMadeYet, where.keys.first.to_s) { kit.lowering.new.build(part_faded(where)) }

      assert_match(/fades part of the screen/, error.message)
    end
  end
end
