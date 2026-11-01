# frozen_string_literal: true

require "test_helper"

# The picture check playing a Super Nintendo cartridge beside the interpreter, which it does only on
# the interpreter's run: every other run compares its own lowered game instead.
class TestPicturesOnTheSuperNintendoInterpreter < Minitest::Test
  include VBlank::Testing::Pictures

  # Building for the Super Nintendo reaches tables and methods a second Ractor cannot share.
  runs_on_the_main_ractor!

  SUPER_NINTENDO = VBlank::Console::SUPER_NINTENDO

  def test_a_super_nintendo_program_is_compared_as_its_cartridge
    oracle, console, = backend_pictures(boxes, frames: 4)

    assert_equal SUPER_NINTENDO.screen_width * SUPER_NINTENDO.screen_height, console.size, "its screen"
    assert_equal Color.resolve(:blue), pixel_at(console, 150, 134), "its blue box"
    assert_empty mismatched_pixels(oracle, console)
  end

  # Each pass moves the box, so only the right pairing of the console's frames with the
  # interpreter's agrees, on a painted screen and on a tiled one — and it is at the frame asked
  # for, so the start-up frames are what Pictures::LINE_UPS says.
  def test_a_moving_picture_lines_up_at_the_frame_asked_for
    asked = [2, 5]
    [boxes, walker].each do |program|
      asked.each do |frame|
        oracle, console, ran = backend_pictures(program, frames: frame)

        assert_equal frame, ran, program.walk.find { |node| node.kind == :screen }.mode
        assert_empty mismatched_pixels(oracle, console)
      end
    end
  end

  private def boxes
    VBlank.game("BOXES", consoles: [:snes]) do
      screen :bitmap
      x = var :x, 8
      game_loop do
        clear_screen :white
        draw_rect_at x, 8, 8, 8, :red
        draw_rect_at 144, 128, 16, 16, :blue
        x += 4
      end
    end.program
  end

  private def walker
    VBlank.game("WALKER", consoles: [:snes]) do
      screen :tiled
      image(:box, "#" => :red) { Array.new(8) { "#" * 8 }.join("\n") }
      hero = sprite :box, at: [0, 20]
      game_loop { hero.x += 4 }
    end.program
  end
end
