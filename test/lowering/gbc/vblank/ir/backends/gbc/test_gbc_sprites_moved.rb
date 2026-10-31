# frozen_string_literal: true

require "test_helper"

# A SPRITE THAT ONLY MOVED A LITTLE keeps its pieces and has their places rewritten where they are
# in the sprite table, which is a tenth of placing it afresh. A screen shaken a pixel a frame moves
# every sprite on it, and placing them all afresh ran the frame over. Every case here is played
# against the interpreter, since what this can get wrong is a piece left in the wrong place.
class TestGBCSpritesMoved < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def built(&game)
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  private def moving(start_x, start_y, step_x, step_y, frames: 40)
    built do
      screen :tiled
      image(:ball, "#" => :red, "o" => :yellow) { (["##oo##oo####oooo"] * 16).join("\n") }
      image(:ball_too, "#" => :yellow, "o" => :red) { (["##oo##oo####oooo"] * 16).join("\n") }
      ball = sprite :shaken, frames: %i[ball ball_too], rate: 100, at: [start_x, start_y]
      tick = var :tick, 0
      game_loop do
        tick += 1
        ball.move_to start_x + (((tick & 7) - 3) * step_x), start_y + (((tick & 7) - 3) * step_y) if tick < frames
      end
    end
  end

  def test_a_big_sprite_shaken_in_the_middle_of_the_screen_stays_where_the_interpreter_has_it
    GBC::CheckedRun.new.run(moving(60, 60, 1, 1), frames: 20)
  end

  def test_a_sprite_shaken_over_the_left_edge_loses_and_gets_back_its_pieces
    GBC::CheckedRun.new.run(moving(-4, 60, 2, 0), frames: 20)
  end

  def test_a_sprite_shaken_over_the_top_edge_loses_and_gets_back_its_pieces
    GBC::CheckedRun.new.run(moving(60, -4, 0, 2), frames: 20)
  end

  def test_a_sprite_shaken_over_the_right_and_bottom_edges_loses_and_gets_back_its_pieces
    GBC::CheckedRun.new.run(moving(150, 134, 2, 2), frames: 20)
  end

  def test_a_sprite_that_jumps_too_far_to_shake_is_placed_afresh
    GBC::CheckedRun.new.run(moving(40, 40, 12, 9), frames: 20)
  end

  def test_a_sprite_that_moves_and_changes_pose_in_one_pass_shows_both
    game = built do
      screen :tiled
      image(:left, "#" => :red, "." => :transparent) { (["####....####...."] * 16).join("\n") }
      image(:right, "#" => :green, "." => :transparent) { (["....####....####"] * 16).join("\n") }
      ball = sprite :ball, frames: %i[left right], rate: 2, at: [50, 50]
      tick = var :tick, 0
      game_loop do
        tick += 1
        ball.move_to 50 + (tick & 1), 50
      end
    end

    GBC::CheckedRun.new.run(game, frames: 12)
  end

  # Sprites that borrow their colours keep them by asking every pass, which moving must not skip.
  def test_sprites_that_borrow_their_colours_keep_them_as_they_shake
    game = built do
      screen :tiled
      balls = (0...8).map do |n|
        8.times do |s|
          colors :"step#{n}_#{s}", [:transparent, VBlank::Graphics::Color.rgb(n * 3, s * 4, 31 - n),
                                    VBlank::Graphics::Color.rgb(s * 3, n * 2, 9)]
        end
        2.times do |pose|
          image :"ball#{n}_#{pose}", width: 16, height: 16, colors: :"step#{n}_0",
                                     places: Array.new(256) { |i| 1 + (((i + pose) % 8) / 4) }
        end
        sprite :"ball#{n}", frames: %i[0 1].map { |pose| :"ball#{n}_#{pose}" }, rate: 100,
                            at: [10 + ((n % 4) * 30), 30 + ((n / 4) * 40)]
      end
      tick = var :tick, 0
      game_loop do
        tick += 1
        balls.each_with_index do |ball, n|
          ball.move_to 10 + ((n % 4) * 30) + (tick & 1), 30 + ((n / 4) * 40)
          ball.draw_with((0...8).map { |s| :"step#{n}_#{s}" }, showing: (tick >> 3) & 7)
        end
      end
    end

    GBC::CheckedRun.new.run(game, frames: 24)
  end

  def test_a_shaken_screen_moves_its_sprites_where_they_are_in_the_table
    rom = VBlank.build("SHAKEN", console: :gbc, out: nil, err: nil, profile: false) do
      screen :tiled
      image(:ball, "#" => :red, "o" => :yellow) { (["##oo##oo####oooo"] * 16).join("\n") }
      image(:ball_too, "#" => :yellow, "o" => :red) { (["##oo##oo####oooo"] * 16).join("\n") }
      balls = Array.new(9) { |n| sprite :"ball_#{n}", frames: %i[ball ball_too], rate: 200, at: [n * 16, (n % 3) * 40] }
      tick = var :tick, 0
      game_loop do
        tick += 1
        balls.each_with_index { |ball, n| ball.move_to (n * 16) + (tick & 1), ((n % 3) * 40) + 8 }
      end
    end

    spent = VBlank::Diagnostics::GBCProfiler.run(rom, frames: 30, settle: 30).runtime.map { |line| line.routine.to_s }

    assert_includes spent, "rt_place_kept_sprite_moved"
    refute_includes spent, "rt_gbc_place_piece", "no piece is placed afresh once the shake is going"
  end
end
