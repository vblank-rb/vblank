# frozen_string_literal: true

require "test_helper"
require "stringio"

# A pool of bullets, each moving every pass: one walk of the pool, each bullet's own fields read and
# written, the ones that leave the screen removed and new ones fired to keep about twelve in the air.
# The commonest walk a game makes. The game's share of the frame, its routines and the pool's own
# together, is what the profiler reads: the part of the frame the console was awake.
class TestGBAPoolBulletsCost < Minitest::Test
  def self.game
    VBlank.game("BULLETS", consoles: %i[gba]) do
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

  # A field update with a register on the thing's record is about 6 cycles (GBATEK, "ARM CPU
  # Instruction Cycle Times"). Kept as lists the bullets kept the console awake 0.82% of every
  # frame; kept as records and walked with r10 on the bullet, 0.37%.
  def test_bullets_take_under_half_a_percent_of_a_frame
    rom = self.class.game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, settle: 60, frames: 60)

    assert_operator 1 - result.idle_share, :<, 0.005
  end
end
