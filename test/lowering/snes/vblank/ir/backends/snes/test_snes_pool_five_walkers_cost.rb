# frozen_string_literal: true

require "test_helper"
require "stringio"

# FIVE THINGS OF A POOL, EACH CHECKED AGAINST THE OTHER FOUR EVERY PASS, as the five enemies of a
# Super Bomberman stage are (bank6.asm, straight_movement calls check_for_enemy_with_enemy_collision
# for each): a routine of the pool steps its thing, walks the pool, and turns its thing round when
# another is within 16 pixels on both axes. Twenty pairs a pass, and the routine's share of the
# frame is what the profiler reads.
class TestSNESPoolFiveWalkersCost < Minitest::Test
  STARTS = [[40, 40], [120, 72], [72, 120], [160, 100], [200, 30]].freeze

  def self.game
    VBlank.game("FIVE WALKERS", consoles: %i[snes]) do
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

  # Measured before the walk and its checks were made cheaper (a363791a7), the routine took 16.2% of
  # every frame; the bound holds what they cost now.
  def test_five_walkers_checking_each_other_take_under_10_and_a_half_percent_of_a_frame
    rom = self.class.game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }

    assert_operator spent.share, :<, 0.105
  end

  # The walkers meet and turn round as on the interpreter, on every pass.
  def test_the_walkers_are_the_interpreters_on_every_pass
    game_player.run(self.class.game.program(console: :snes), frames: 60)
  end
end
