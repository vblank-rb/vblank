# frozen_string_literal: true

require "test_helper"

# TEXT ON A PAINTED SCREEN IS A FEW CELLS OF A MAP, as the console's own games keep it
# (Runtime::TextLayer): four rows of 21 letters cost their first pass what an unchanged pass
# costs. Painted into tiles of eight bits a pixel they were nearly a frame of painting and about
# 6K to send, more than a blank holds, so the first pass took four frames. Read off the console
# in bsnes, the picture held to the interpreter's on every pass.
class TestSNESTextLayerCost < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_four_rows_of_text_take_one_frame_on_their_first_pass
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        4.times { |row| draw_text "ABCDEFGHIJKLMNOPQRSTU", 8, 40 + (row * 20), :white }
      end
    end
    SNES::CheckedRun.new.run(program, frames: 5)
    run = SNES::HeadlessRun.new.run(program, frames: 5)

    assert_equal [1] * 4, (2..5).map { |pass| run.frames_took(pass) }
  end

  # Text that changes as the game runs beside text that does not: each pass the changed words
  # are a few cells, and nothing is painted.
  def test_words_that_change_every_pass_take_one_frame
    program = program_of do
      screen :bitmap
      n = 0
      game_loop do
        clear_screen :black
        4.times { |row| draw_text "ABCDEFGHIJKLMNOPQRSTU", 8, 40 + (row * 20), :white }
        if n % 2 == 0
          draw_text "PLAYER ONE", 8, 140, :yellow
        else
          draw_text "PLAYER TWO", 8, 140, :yellow
        end
        n += 1
      end
    end
    SNES::CheckedRun.new.run(program, frames: 8)
    run = SNES::HeadlessRun.new.run(program, frames: 8)

    assert_equal [1] * 7, (2..8).map { |pass| run.frames_took(pass) }
  end

  # More words than the layer has tiles for: the rest are painted, and the picture is the
  # interpreter's.
  def test_more_words_than_the_layer_holds_are_painted
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        24.times { |row| draw_text format("ROW %02d OF MANY WORDS", row), 3, 2 + (row * 9), :white }
      end
    end
    SNES::CheckedRun.new.run(program, frames: 4)
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end
end
