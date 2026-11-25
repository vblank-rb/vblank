# frozen_string_literal: true

require "test_helper"

# A sprite of several poses walking many lists of colours keeps a row for every pose under every list,
# poses times lists, and a few such sprites fading through a screen's worth of lists come to more than
# the part of a Color cartridge always in view holds beside the game's code. Such a game is built
# with those rows in the cartridge's banks (GBC#build), read with their bank put in view, and plays as
# it does on the interpreter.
class TestGBCBankedTables < Minitest::Test
  SPRITES = 12
  POSES = 5
  LISTS = 50

  private def many_posed_sprites_walking_many_lists
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      LISTS.times { |s| colors :"fade#{s}", [:transparent, rgb(s % 32, 31 - (s % 32), 8), rgb(4, s % 32, 31 - (s % 32))] }
      poses = (0...POSES).map do |p|
        image :"ball#{p}", width: 8, height: 8, colors: :fade0, places: Array.new(64) { |i| 1 + (((i + p) % 8) / 4) }
        :"ball#{p}"
      end
      # Six to a row: a Color draws ten sprites on a row of the screen at most.
      balls = (0...SPRITES).map { |n| sprite :"ball_sprite#{n}", at: [8 + ((n % 6) * 16), 40 + ((n / 6) * 24)], frames: poses, rate: 2 }
      # A table the game reads, which the build keeps a note of beside the pose tables.
      steps = table :steps, (0...LISTS).map { |s| (s + 1) % LISTS }
      step = var :step, 0
      game_loop do
        step = steps[step]
        balls.each { |ball| ball.draw_with((0...LISTS).map { |s| :"fade#{s}" }, showing: step) }
      end
    end
    b.finalize_program
    b.program
  end

  # The same sprites standing still, each given its pose by a variable and its lists once: a sprite
  # kept as it was is placed from rows kept in the banks too, its picture changed where it is in the
  # table when only its pose or its list changed, and placed afresh when it moves.
  private def still_sprites_walking_many_lists
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      LISTS.times { |s| colors :"fade#{s}", [:transparent, rgb(s % 32, 31 - (s % 32), 8), rgb(4, s % 32, 31 - (s % 32))] }
      poses = (0...POSES).map do |p|
        image :"ball#{p}", width: 8, height: 8, colors: :fade0, places: Array.new(64) { |i| 1 + (((i + p) % 8) / 4) }
        :"ball#{p}"
      end
      step = var :step, 0
      pose = var :pose, 0
      tick = var :tick, 0
      balls = (0...SPRITES).map do |n|
        ball = sprite :"ball_sprite#{n}", at: [8 + ((n % 6) * 16), 40 + ((n / 6) * 24)], facing: poses.to_h { |p| [p, p] }
        ball.draw_with((0...LISTS).map { |s| :"fade#{s}" }, showing: step)
        ball
      end
      game_loop do
        tick += 1
        pose = (pose + 1) % POSES if tick % 2 == 0
        step = (step + 7) % LISTS if tick % 3 == 0
        balls.first.x += 1 if tick % 5 == 0
        balls.each { |ball| ball.face(poses, showing: pose) }
      end
    end
    b.finalize_program
    b.program
  end

  # +count+ tables of the game's own, +entries+ long and each smaller than a table is kept in banks
  # for by itself, but too many together for the part always in view. The game reads every one of
  # them each pass, at an index that moves.
  private def many_tables(count, entries)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      tables = (0...count).map { |n| table :"forces#{n}", Array.new(entries) { |i| ((i * 37) + (n * 11)) % 900 - 450 } }
      at = 0
      total = 0
      game_loop do
        at += 13
        tables.each { |forces| total += forces[at] }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_game_can_keep_more_tables_than_fit_in_view
    game_player.run(many_tables(40, 256), frames: 4)
  end

  def test_a_game_can_keep_more_small_tables_than_fit_in_view
    game_player.run(many_tables(230, 40), frames: 4)
  end

  def test_tables_that_fit_in_view_stay_in_view
    built = VBlank::Console.for(:gbc).builder.cartridge_for(many_tables(4, 256), title: "INVIEW").built

    assert_empty built.code.keys.grep(/\Atable .* part /), "no table goes to a bank while they fit"
  end

  def test_sprites_whose_pose_rows_do_not_fit_in_view_still_build_and_play
    game_player.run(many_posed_sprites_walking_many_lists, frames: 12)
  end

  def test_still_sprites_whose_pose_rows_do_not_fit_in_view_play_as_on_the_interpreter
    game_player.run(still_sprites_walking_many_lists, frames: 30)
  end
end
