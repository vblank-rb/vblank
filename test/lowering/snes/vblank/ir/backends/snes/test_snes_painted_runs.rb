# frozen_string_literal: true

require "test_helper"

# A painted picture keeps each row already shifted for each place across modulo eight it can be
# painted at (SNES::PaintedArt), and only those: a picture at one written place keeps one run of
# its rows, one at a place worked out as the game runs keeps all eight. Measured on the built
# cartridge, as the bytes between a picture's first row and its second; and painted at every
# place, the picture is the interpreter's on every pass (SNES::CheckedRun), on a plain cartridge
# and on one with a Super FX, whose chip reads the same runs.
class TestSNESPaintedRuns < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # The picture is 16 pixels wide, so a row reaches three tiles across: a run is three columns of
  # ten bytes.
  RUN_BYTES = 30

  def test_a_picture_at_one_written_place_keeps_one_run
    assert_equal RUN_BYTES, row_bytes { blit :bar, 13, 20 }
  end

  def test_a_picture_at_written_places_eight_apart_keeps_one_run
    assert_equal RUN_BYTES, row_bytes {
      blit :bar, 13, 20
      blit :bar, 29, 40
    }
  end

  def test_a_picture_at_two_written_places_keeps_two_runs
    assert_equal 2 * RUN_BYTES, row_bytes {
      blit :bar, 13, 20
      blit :bar, 14, 40
    }
  end

  def test_a_picture_at_a_place_worked_out_as_the_game_runs_keeps_all_eight
    assert_equal 8 * RUN_BYTES, row_bytes {
      x = 5
      game_loop do
        blit :bar, x, 20
        x += 1
      end
    }
  end

  def test_a_picture_at_a_column_times_eight_plus_a_written_number_keeps_one_run
    assert_equal RUN_BYTES, row_bytes {
      column = 2
      game_loop do
        blit :bar, (column * 8) + 3, 20
        column += 1
      end
    }
  end

  def test_pictures_at_every_place_across_paint_as_on_the_interpreter
    SNES::CheckedRun.new.run(every_place_program, frames: 10)
  end

  def test_pictures_at_every_place_across_paint_as_on_the_interpreter_on_the_super_fx
    SNES::CheckedRun.new.run(every_place_program.tap { |game| game.variant = :superfx }, frames: 10)
  end

  # Written places at each place modulo eight, the same picture at a place worked out as the game
  # runs, and text (whose place is always written) in one colour and in a colour picked, and digits.
  private def every_place_program
    program_of do
      screen :bitmap
      bar_image
      x = 0
      column = 1
      game_loop do
        clear_screen :black
        8.times { |shift| blit :bar, 3 + (shift * 17), 4 + (shift * 3) }
        blit :bar, x, 40
        blit :bar, (column * 8) + 5, 50
        draw_text "AB", 9, 60, :white
        draw_text "CD", 70, 60, %i[yellow green], showing: x % 2 == 1
        draw_number x, 13, 80, :white, digits: 2
        x += 1
        column += 1
      end
    end
  end

  # The bytes from the first row of picture 0, the bar, to its second, in a cartridge built of
  # +paint+.
  private def row_bytes(&paint)
    program = program_of do
      screen :bitmap
      bar_image
      instance_eval(&paint)
    end
    code = SNES.new.build(program).built.code
    code.fetch("paint row 0.1") - code.fetch("paint row 0.0")
  end

  private def program_of(&game)
    builder = Builder.new
    builder.define_singleton_method(:bar_image) do
      image :bar, "." => :transparent, "r" => :red, "g" => :green do
        "rr.g..rrrr.gg..r\n.r..gg..r..g.rr.\n"
      end
    end
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end
end
