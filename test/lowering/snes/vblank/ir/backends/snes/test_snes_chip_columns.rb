# frozen_string_literal: true

require "test_helper"

# `draw_column_at` in a routine marked `on_chip: true`, on a Super FX cartridge: a first-person
# view's walls, a column of a picture stretched to a height for each column of the screen, drawn
# by the chip. Each game is played and checked against the interpreter on every frame, so a
# column the chip stretches, clips or leaves see-through differently fails at the first frame.
class TestSNESChipColumns < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # A wall 64 pixels square in stripes: eight bands down, each its own colour, and every fourth
  # column across darker, so a texel read from the wrong row or the wrong column shows.
  BANDS = %i[red green blue white yellow cyan magenta orange].freeze
  WALL = Array.new(64 * 64) do |at|
    row = at / 64
    column = at % 64
    column % 4 == 3 ? :gray : BANDS[row / 8]
  end.freeze
  # A picture with see-through holes, which leave what is under them alone.
  GRATE = Array.new(16 * 16) { |at| (at / 16).even? ? :transparent : :green }.freeze

  private def superfx_program(game) = game.program(console: :snes, variant: :superfx)

  # +columns+ wall columns a pass, their heights changing from pass to pass through tall ones that
  # run off the top and the bottom of the screen, short ones squashed below the picture's own
  # height, and nought and below.
  private def walls(columns:, area: false)
    VBlank.game("CHIP WALLS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      image :grate, width: 16, height: 16, data: GRATE, transparent: true
      step = var :step, 0
      tall = var :_tall, 0

      func :walls, on_chip: true do
        repeat(columns) do |col|
          tall = (((col * 37) + (step * 23)) % 400) - 20
          draw_column_at :wall, slice: (col * 3) + step, x: col * 2, top: 112 - (tall / 2), height: tall
        end
        draw_column_at :grate, slice: step, x: 200, top: step - 4, height: 40 + step, width: 3
        draw_column_at :wall, slice: 5, x: 255, top: 0, height: 30, width: 2
        draw_column_at :wall, slice: 70, x: -1, top: 0, height: 30, width: 2
      end

      game_loop do
        clear_screen :black
        step += 1
        if area
          inside(20, 30, 100, 120) { call :walls }
        else
          call :walls
        end
      end
    end
  end

  def test_walls_drawn_on_the_chip_look_as_on_the_interpreter
    run = game_player.run(superfx_program(walls(columns: 40)), frames: 30)

    assert_operator run[:step], :>=, 10, "ten passes or more were checked"
  end

  def test_walls_drawn_on_the_chip_inside_an_area_look_as_on_the_interpreter
    run = game_player.run(superfx_program(walls(columns: 40, area: true)), frames: 20)

    assert_operator run[:step], :>=, 5, "five passes or more were checked"
  end

  # +columns+ columns of the striped wall, each +tall+ high, drawn from a routine on the chip or
  # on the console.
  private def square_of_walls(columns:, tall:, on_chip:)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes, variant: :superfx))
    b.instance_eval do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      func :walls, on_chip: on_chip do
        repeat(columns) { |col| draw_column_at :wall, slice: col, x: col, top: 112 - (tall / 2), height: tall }
      end
      game_loop do
        clear_screen :black
        call :walls
      end
    end
    b.finalize_program
    b.program
  end

  # The most frames one of two passes past the first took, with frames enough for both however
  # slow: the console's passes are past a hundred frames.
  private def frames_a_pass(program)
    run = SNES::HeadlessRun.new.run(program, frames: 360)
    (2...4).map { |pass| run.frames_took(pass) }.max
  end

  # The walls of a first-person view, 120 columns 120 high and 40 columns 40 high, take a third of
  # the frames on the chip that they take on the console or fewer.
  [[120, 120], [40, 40]].each do |columns, tall|
    define_method(:"test_#{columns}_columns_#{tall}_high_take_far_fewer_frames_on_the_chip") do
      on_console = frames_a_pass(square_of_walls(columns: columns, tall: tall, on_chip: false))
      on_the_chip = frames_a_pass(square_of_walls(columns: columns, tall: tall, on_chip: true))
      warn "#{columns}x#{tall}: #{on_console} frames a pass on the 65816, #{on_the_chip} on the chip" if ENV["VBLANK_CHIP_FRAMES"]

      assert_operator on_the_chip * 3, :<=, on_console, "the chip took a third of the frames or fewer"
    end
  end
end
