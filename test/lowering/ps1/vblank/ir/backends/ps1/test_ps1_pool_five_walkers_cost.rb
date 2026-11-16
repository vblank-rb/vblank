# frozen_string_literal: true

require "test_helper"
require "stringio"

# FIVE THINGS OF A POOL, EACH CHECKED AGAINST THE OTHER FOUR EVERY PASS: a routine of the pool
# steps its thing, walks the pool, and turns its thing round when another is within 16 pixels on
# both axes. Twenty pairs a pass, and the routine's share of the frame is what the profiler reads.
class TestPS1PoolFiveWalkersCost < Minitest::Test
  STARTS = [[40, 40], [120, 72], [72, 120], [160, 100], [200, 30]].freeze

  def self.game
    VBlank.game("FIVE WALKERS", consoles: %i[ps1]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      enemies = pool :enemy, place_x: 0, place_y: 0, dx: 0, dy: 0, capacity: 8
      STARTS.each_with_index do |(x, y), i|
        enemies.spawn(place_x: x, place_y: y, dx: i.even? ? 1 : -1, dy: (i % 3).zero? ? 1 : -1)
      end
      enemies.func(:step_straight) do |e|
        e.place_x += e.dx
        e.place_y += e.dy
        enemies.each do |other|
          if other.index != e.index && (other.place_x - e.place_x).abs < 16 && (other.place_y - e.place_y).abs < 16
            e.dx = 0 - e.dx
            e.dy = 0 - e.dy
          end
        end
      end
      game_loop do
        enemies.each { |_enemy| call :step_straight }
      end
    end
  end

  # Kept as lists the routine took 0.55% of every frame; kept as tables and walked with s7 on the
  # thing (PS1::Lowering#emit_stepped_walk), 0.36%.
  def test_five_walkers_checking_each_other_take_under_0_45_percent_of_a_frame
    rom = self.class.game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }

    assert_operator spent.share, :<, 0.0045
  end

  # The walkers meet and turn round as on the interpreter, on every pass.
  def test_the_walkers_are_the_interpreters_on_every_pass
    game_player.run(self.class.game.program(console: :ps1), frames: 60)
  end
end
