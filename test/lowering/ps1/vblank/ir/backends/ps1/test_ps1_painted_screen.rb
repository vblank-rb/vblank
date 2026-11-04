# frozen_string_literal: true

require "test_helper"

# What only the PlayStation's own program can show about a painted screen: where the picture is in
# its video RAM, read straight from the emulator (PS1::HeadlessRun), and that the checked run reads
# every pixel of it. What the verbs draw is in test/all, where this run plays them against the
# interpreter pixel for pixel.
class TestPS1PaintedScreen < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  RED = VBlank::Graphics::Color.resolve(:red)

  def test_a_screen_cleared_to_a_colour_shows_it_on_every_pixel
    run = PS1::HeadlessRun.new.run(program_of do
      game_loop { clear_screen :blue }
    end, frames: 3)

    assert_equal [BLUE] * (320 * 240), run.screen.shown
  end

  # The checked run compares the whole picture: the screen the interpreter plays is the PlayStation's,
  # its bottom right corner included. (The builder checks a written number against the Advance's
  # screen, so the corner is a number the game works out.)
  def test_the_checked_run_reads_the_whole_picture
    run = PS1::CheckedRun.new.run(program_of do
      right = 319
      bottom = 239
      game_loop do
        clear_screen :blue
        draw_rect_at right, bottom, 1, 1, :red
      end
    end, frames: 3)

    assert_equal [320, 240], [run.screen.width, run.screen.height]
    assert_equal RED, run.screen.pixel(319, 239)
    assert_equal BLUE, run.screen.pixel(318, 239)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end
end
