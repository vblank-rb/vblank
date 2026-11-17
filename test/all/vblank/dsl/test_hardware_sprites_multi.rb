# frozen_string_literal: true

require "test_helper"

# Multiple hardware sprites at once (OAM slice 2): several sprites keep their own
# colors, stack in a stable front-to-back order (the thing software save-under
# sprites can't do reliably), and can be hidden and shown. Asserted on the
# interpreter oracle and on real hardware. Still no OAM, tile indices, or palette
# banks in the game code.
#
# The same games on the Advance's cartridge, read in the emulator, are in
# test/lowering/gba/vblank/dsl/test_hardware_sprites_multi_cartridge.rb.

# The games both files play.
module HardwareSpritesMultiGames
  include SharedConstants

  # A white floor filling the screen. Shareable, as a test class's constant is made for it, so a
  # test in a Ractor can read it.
  FLOOR_MAP = Ractor.make_shareable(Array.new(20, "#" * 30))

  # Two overlapping sprites: a red one declared first, a blue one declared second,
  # each a different color (so this also proves they share one palette without
  # clobbering each other). They overlap in 44..47 x 44..47.
  private def overlapping_pair
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :white) { SOLID_TILE }
      image(:red_guy,  "#" => :red)  { SOLID_TILE }
      image(:blue_guy, "#" => :blue) { SOLID_TILE }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      sprite :red_guy,  at: [40, 40] # declared first  -> behind
      sprite :blue_guy, at: [44, 44] # declared second -> in front
      game_loop do
        wait_vblank
        halt # a static scene — one frame is enough
      end
    end
    builder.finalize_program
    builder.program
  end

  # One red sprite over a white floor that flips visibility once, on frame 1. A
  # sprite that starts +shown+ hides itself; one that starts hidden shows itself. So
  # the observable result at the sprite's spot (44, 44) inverts between a 1-frame run
  # (before the flip) and a longer run (after it).
  private def visibility_program(shown:, frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :white) { SOLID_TILE }
      image(:guy,   "#" => :red)   { SOLID_TILE }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      guy = sprite :guy, at: [40, 40], shown: shown
      f = var :f, 0
      game_loop do
        wait_vblank
        shown ? guy.hide : guy.show if f == 1
        f += 1
        halt if f >= frames
      end
    end
    builder.finalize_program
    builder.program
  end

  # Six red sprites in a row over the white floor, at x = 20, 44, ... 140, inside the Color's screen too. All six show on pass 0;
  # on pass 1 the last four hide; on pass 3 the fifth shows again; on pass 5 all hide. A console
  # that keeps a table of what it drew must switch off what each pass dropped, and only that.
  private def dropping_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :white) { SOLID_TILE }
      image(:guy,   "#" => :red)   { SOLID_TILE }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      guys = Array.new(6) { |i| sprite :guy, at: [20 + (i * 24), 40] }
      f = var :f, 0
      game_loop do
        wait_vblank
        guys.drop(2).each(&:hide) if f == 1
        guys[4].show if f == 3
        guys.each(&:hide) if f == 5
        f += 1
        halt if f >= frames
      end
    end
    builder.finalize_program
    builder.program
  end
end

class TestHardwareSpritesMulti < Minitest::Test
  include VBlank::Console::Hardware
  include HardwareSpritesMultiGames

  def test_later_declared_sprite_draws_in_front_and_colors_do_not_clobber
    screen = game_player.run(overlapping_pair).screen
    assert_equal Color.resolve(:red),  screen.pixel(41, 41), "the red sprite keeps its own color"
    assert_equal Color.resolve(:blue), screen.pixel(50, 50), "the blue sprite keeps its own color"
    assert_equal Color.resolve(:blue), screen.pixel(46, 46), "the later sprite sits in front in the overlap"
  end

  private def spot_color(program)
    game_player.run(program).screen.pixel(44, 44)
  end

  def test_a_shown_sprite_can_be_hidden
    assert_equal Color.resolve(:red),   spot_color(visibility_program(shown: true, frames: 1)),
                 "before the flip the sprite is visible"
    assert_equal Color.resolve(:white), spot_color(visibility_program(shown: true, frames: 4)),
                 "after hide, its spot shows the floor again"
  end

  # Which of the six sprites of #dropping_program are red after +frames+.
  private def red_guys(frames)
    screen = game_player.run(dropping_program(frames: frames)).screen
    (0...6).select { |i| screen.pixel(24 + (i * 24), 44) == Color.resolve(:red) }
  end

  def test_sprites_dropped_from_a_pass_vanish_and_come_back
    assert_equal [0, 1, 2, 3, 4, 5], red_guys(1), "all six show at first"
    assert_equal [0, 1], red_guys(3), "four hidden: their spots show the floor"
    assert_equal [0, 1, 4], red_guys(5), "the fifth shows again"
    assert_empty red_guys(8), "every one hidden"
  end

  def test_a_hidden_sprite_can_be_shown
    assert_equal Color.resolve(:white), spot_color(visibility_program(shown: false, frames: 1)),
                 "a shown: false sprite starts invisible"
    assert_equal Color.resolve(:red),   spot_color(visibility_program(shown: false, frames: 4)),
                 "after show, the sprite appears"
  end
end
