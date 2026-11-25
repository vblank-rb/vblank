# frozen_string_literal: true

require "test_helper"
require "stringio"

# A pool of bullets, each moving every pass: one walk of the pool, each bullet's own fields read and
# written, the ones that leave the screen removed and new ones fired to keep about twelve in the air.
# The commonest walk a game makes. The game's share of the frame, its routines and the pool's own
# together, is what the profiler reads.
class TestGBCPoolBulletsCost < Minitest::Test
  def self.game
    VBlank.game("BULLETS", consoles: %i[gbc]) do
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

  # A 16-bit field add in the console's own object update is about 56 cycles with HL on the record
  # (Pokemon Pinball's UpdateSeelPosition, pret/pokepinball). Kept as lists the bullets took 15.71%
  # of every frame; kept as tables and walked by the bullet's distance, each field HL set from it,
  # 10.17%.
  def test_bullets_take_under_11_percent_of_a_frame
    rom = self.class.game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    rows = rom.profile(out: StringIO.new, settle: 60, frames: 60).game

    assert_operator rows.sum(&:share), :<, 0.11
  end

  # The bullets move, leave and are fired as on the interpreter, on every pass.
  def test_the_bullets_are_the_interpreters_on_every_pass
    game_player.run(self.class.game.program(console: :gbc), frames: 120)
  end
end
