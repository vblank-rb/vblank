# frozen_string_literal: true

require "test_helper"
require "interpreter/vblank/testing/test_pictures_on_each_console_interpreter"

# The picture check playing a Super Nintendo cartridge beside the interpreter, which it does only on
# the interpreter's run: every other run compares its own lowered game instead.
class TestPicturesOnTheSuperNintendoInterpreter < Minitest::Test
  include VBlank::Testing::Pictures
  include MovingPictureGames

  # bsnes is opened through Fiddle, a C extension Ruby refuses to run outside the main Ractor.
  runs_on_the_main_ractor!

  SUPER_NINTENDO = VBlank::Console::SUPER_NINTENDO

  def test_a_super_nintendo_program_is_compared_as_its_cartridge
    oracle, console, = backend_pictures(boxes(:snes), frames: 4)

    assert_equal SUPER_NINTENDO.screen_width * SUPER_NINTENDO.screen_height, console.size, "its screen"
    assert_equal Color.resolve(:blue), pixel_at(console, 150, 134), "its blue box"
    assert_empty mismatched_pixels(oracle, console)
  end

  # So the Super Nintendo's start-up frames are what Pictures::LINE_UPS says.
  def test_a_moving_picture_lines_up_at_the_frame_asked_for
    assert_lines_up_at_the_frame_asked_for(:snes)
  end
end
