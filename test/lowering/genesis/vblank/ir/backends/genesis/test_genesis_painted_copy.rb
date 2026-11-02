# frozen_string_literal: true

require "test_helper"

# How a painted screen reaches the console: a clear to the colour the screen already is costs nothing,
# a change is copied by DMA a blank's worth at a time, and a picture wholly on the screen is walked a
# byte at a time. Each game plays on the cartridge and the interpreter together (Genesis::CheckedRun).
class TestGenesisPaintedCopy < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  LETTER = ".##.\n#..#\n####\n#..#\n"

  def test_a_game_that_clears_and_draws_text_every_pass_takes_a_frame_a_pass
    run = Genesis::HeadlessRun.new
    run.run(program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        draw_text "THREE", 16, 16, :white
      end
    end, frames: 8)

    assert_equal [1] * 7, (1..7).map { |pass| run.frames_took(pass) }
  end

  def test_the_whole_screen_changing_colour_every_pass_agrees_over_several_blanks
    run = Genesis::CheckedRun.new.run(program_of do
      screen :bitmap
      flip = var :flip, 0
      game_loop do
        flip = 1 - flip
        if flip == 1
          clear_screen :blue
        else
          clear_screen :red
        end
      end
    end, frames: 30)

    assert_operator run.frames_took(3), :>, 1, "more tiles than one blank holds take more than one frame"
  end

  def test_a_clear_after_painting_puts_back_what_the_painting_changed
    Genesis::CheckedRun.new.run(program_of do
      screen :bitmap
      t = var :t, 0
      game_loop do
        clear_screen :black
        t += 1
        fill_rect 20, 20, 30, 30, :red if t % 2 == 1
        pixel 200, 100, :green if t % 2 == 0
      end
    end, frames: 12)
  end

  def test_pictures_at_every_half_of_a_byte_and_across_tiles_agree
    Genesis::CheckedRun.new.run(program_of do
      screen :bitmap
      image(:letter, "#" => :white, "." => :transparent) { LETTER }
      clear_screen :blue
      (0..9).each { |x| blit :letter, 3 + (x * 7), 5 + x }
      game_loop { nil }
    end, frames: 3)
  end

  def test_a_picture_part_off_the_screen_or_outside_an_area_agrees
    Genesis::CheckedRun.new.run(program_of do
      screen :bitmap
      image(:letter, "#" => :white, "." => :transparent) { LETTER }
      clear_screen :blue
      blit :letter, -2, -1
      blit :letter, 318, 222
      inside(10, 10, 3, 3) { blit :letter, 9, 9 }
      game_loop { nil }
    end, frames: 3)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
