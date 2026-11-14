# frozen_string_literal: true

require "test_helper"

# A PAINTED SCREEN ON A SUPER FX CARTRIDGE THAT PAINTS WHAT THE LAST PASS PAINTED (Runtime::RepeatLog):
# the pass is passed over, and nothing is painted or sent. Each game is checked against the
# interpreter on every pass in bsnes, so a pass passed over that should not have been, or one made
# again wrongly, fails at the first pass it shows.
class TestSNESRepeatLog < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  BALL = Array.new(16 * 16) { |at| ((at / 16) + (at % 16)).even? ? :yellow : :green }.freeze

  private def program_of(variant, &game)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes, variant: variant))
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  private def superfx(&game) = program_of(:superfx, &game)

  # The passes a cost is measured over, past the first few, which set the screen up.
  MEASURED_PASSES = (6...18)

  private def slowest_pass(program)
    run = SNES::HeadlessRun.new.run(program, frames: MEASURED_PASSES.end + 4)
    MEASURED_PASSES.map { |pass| run.frames_took(pass) }.max
  end

  TWO_HUNDRED_PIXELS = proc do
    screen :bitmap
    game_loop do
      clear_screen :black
      200.times { |n| pixel (n * 7) % 256, (n * 13) % 224, :white }
    end
  end

  TEN_TEXTS = proc do
    screen :bitmap
    game_loop do
      clear_screen :black
      10.times { |n| draw_text "SCORE #{n}", 8, 8 + (n * 20), :white }
    end
  end

  # The same screen every pass takes no more frames on the Super FX than on a plain cartridge.
  { "200_pixels" => TWO_HUNDRED_PIXELS, "10_texts" => TEN_TEXTS }.each do |name, game|
    define_method(:"test_#{name}_take_no_longer_than_on_a_plain_cartridge") do
      plain = slowest_pass(program_of(nil, &game))
      chip = slowest_pass(superfx(&game))

      assert_operator chip, :<=, plain, "#{name}: #{chip} frames a pass on the Super FX, #{plain} on a plain cartridge"
    end
  end

  def test_the_same_screen_every_pass_looks_as_on_the_interpreter
    game = superfx do
      screen :bitmap
      passes = var :passes, 0
      game_loop do
        clear_screen :black
        10.times { |n| draw_text "SCORE #{n}", 8, 8 + (n * 20), :white }
        passes += 1
      end
    end
    run = game_player.run(game, frames: 12)

    assert_operator run[:passes], :>=, 10, "ten passes or more were checked"
  end

  # Passes that are the same as the last for a while, then differ in the middle, at the end, by
  # stopping short, by painting one thing more, in an area, or in another clear colour.
  def test_passes_that_differ_from_the_last_in_every_way_look_as_on_the_interpreter
    game = superfx do
      screen :bitmap
      image :ball, width: 16, height: 16, data: BALL
      step = var :step, 0
      game_loop do
        step += 1
        phase = var :_phase, 0
        phase = (step / 3) % 7
        if phase == 6
          clear_screen :blue
        else
          clear_screen :black
        end
        fill_rect 10, 10, 60, 20, :red
        if phase == 1
          blit :ball, 40 + step, 60
        else
          blit :ball, 40, 60
        end
        draw_text "HELLO", 100, 100, :white
        inside(0, 120, 128, 40) { fill_rect 0, 130, 200, 10, :green } if phase != 3
        fill_rect 200, 200, 20, 10, :white if phase == 4
        clear_screen :black if phase == 5
        draw_text "AGAIN", 30, 180, :yellow if phase == 5
      end
    end
    run = game_player.run(game, frames: 50)

    assert_operator run[:step], :>=, 40, "forty passes or more were checked"
  end

  # A pass that does not clear paints on what the last one left, and the pass after it is not
  # taken for the same as the one before.
  def test_a_pass_that_does_not_clear_looks_as_on_the_interpreter
    game = superfx do
      screen :bitmap
      step = var :step, 0
      game_loop do
        step += 1
        clear_screen :black if step % 4 != 2
        fill_rect 20, 20, 30, 30, :red
        fill_rect (step % 4) * 40, 100, 10, 10, :white if step % 4 == 2
      end
    end
    run = game_player.run(game, frames: 24)

    assert_operator run[:step], :>=, 20
  end

  # Walls drawn on the chip are painted as nothing writes down, with a score over them that is the
  # same every pass.
  def test_walls_on_the_chip_under_a_score_look_as_on_the_interpreter
    wall = Array.new(64 * 64) { |at| (at % 64).even? ? :red : :blue }
    game = superfx do
      screen :bitmap
      image :wall, width: 64, height: 64, data: wall
      step = var :step, 0
      func :walls, on_chip: true do
        repeat(20) { |col| draw_column_at :wall, slice: col + step, x: col * 4, top: 60, height: 40 + (step % 3) }
      end
      game_loop do
        step += 1
        clear_screen :black
        draw_text "SCORE", 8, 8, :white
        call :walls if step % 5 != 0
        draw_text "LIVES", 8, 200, :white
      end
    end
    run = game_player.run(game, frames: 30)

    assert_operator run[:step], :>=, 20
  end
end
