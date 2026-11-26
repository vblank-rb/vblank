# frozen_string_literal: true

require "test_helper"
require "interpreter/vblank/testing/test_pictures_on_each_console_interpreter"

# The picture check playing a Genesis cartridge beside the interpreter, which it does only on
# the interpreter's run: every other run compares its own lowered game instead.
class TestPicturesOnTheGenesisInterpreter < Minitest::Test
  include VBlank::Testing::Pictures
  include MovingPictureGames

  GENESIS = VBlank::Console::GENESIS

  def test_a_genesis_program_is_compared_as_its_cartridge
    oracle, console, = backend_pictures(boxes(:genesis), frames: 4)

    assert_equal GENESIS.screen_width * GENESIS.screen_height, console.size, "its screen"
    assert_equal Color.resolve(:blue), pixel_at(console, 150, 134), "its blue box"
    assert_empty mismatched_pixels(oracle, console)
  end

  # So a Genesis picture is compared at the frame asked for, however long its cartridge sets up.
  def test_a_moving_picture_lines_up_at_the_frame_asked_for
    assert_lines_up_at_the_frame_asked_for(:genesis)
  end

  # A program with no loop shows its painted screen only after the cartridge's boot frames: seven
  # is the least that works, measured.
  def test_a_still_painted_program_is_compared_after_its_first_frame
    program = VBlank.game("STILL", consoles: [:genesis]) do
      screen :bitmap
      clear_screen :white
      draw_rect_at 144, 128, 16, 16, :blue
      halt
    end.program(console: :genesis)

    oracle, console, = backend_pictures(program, frames: 1)

    assert_empty mismatched_pixels(oracle, console)
  end
end
