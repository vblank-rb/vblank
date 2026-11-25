# frozen_string_literal: true

require "test_helper"
require "stringio"

# A pool of bullets, each moving every pass: one walk of the pool, each bullet's own fields read and
# written, the ones that leave the screen removed and new ones fired to keep about twelve in the air.
# The commonest walk a game makes, so a change to how the Super Nintendo keeps or walks a pool must
# leave it no slower. The game's share of the frame, its routines and the pool's own together, is
# what the profiler reads.
class TestSNESPoolBulletsCost < Minitest::Test
  def self.game
    VBlank.game("BULLETS", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      bullets = pool :bullet, x: 0, y: 0, dx: 0, dy: 0, capacity: 16
      fired = var :fired, 0
      game_loop do
        bullets.each do |b|
          b.x += b.dx
          b.y += b.dy
          b.remove if b.x > 240
        end
        if bullets.count < 12
          fired += 1
          bullets.spawn(x: 0, y: (fired * 37) % 200, dx: (fired % 5) + 2, dy: (fired % 3) - 1)
        end
      end
    end
  end

  # Measured at 31243f643, before the Super Nintendo kept a pool its own way: 7.8% of every frame;
  # kept as tables and walked a turn at a time in X (Backends::PoolLayout::Tables), 7.25%.
  def test_bullets_take_no_more_of_a_frame_than_before
    rom = self.class.game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rows = rom.profile(out: StringIO.new, settle: 60, frames: 60).game

    assert_operator rows.sum(&:share), :<=, 0.069
  end

  # The bullets move, leave and are fired as on the interpreter, on every pass.
  def test_the_bullets_are_the_interpreters_on_every_pass
    game_player.run(self.class.game.program(console: :snes), frames: 120)
  end
end
