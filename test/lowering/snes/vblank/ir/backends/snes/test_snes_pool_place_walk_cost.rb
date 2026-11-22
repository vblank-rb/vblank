# frozen_string_literal: true

require "test_helper"
require "stringio"

# Five things of a pool walking a maze of 16-pixel squares, as a stage's enemies do: each pass a
# routine of the pool runs for each thing, nudges it toward the middle of its square across its
# way, steps it by a table of signed halves, and checks it against every other thing of the pool.
# The places are kept in 256ths of a pixel, `:unsigned_half`, so a place's pixel is `place >> 8`,
# and how far apart two things are is worked out in pixels into variables of the game's own.
# Twenty pairs a pass, and the routine's share of the frame is what the profiler reads.
class TestSNESPoolPlaceWalkCost < Minitest::Test
  # Two pairs face each other and meet within a few passes; the last thing is off its middle row.
  STARTS = [[40, 40], [64, 40], [120, 72], [120, 100], [200, 30]].freeze
  DIRECTIONS = [0, 2, 1, 3, 0].freeze

  def self.game
    VBlank.game("PLACE WALK", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      enemies = pool :enemy, place_x: 0, place_y: 0, dir: 0, capacity: 8,
                             widths: { place_x: :unsigned_half, place_y: :unsigned_half, dir: :byte }
      STARTS.each_with_index { |(x, y), i| enemies.spawn(place_x: x * 256, place_y: (y * 256) + 128, dir: DIRECTIONS[i]) }
      step_x = table :step_x, [96, 0, -96, 0], width: :half
      step_y = table :step_y, [0, 96, 0, -96], width: :half
      apart_x = var :apart_x, 0
      apart_y = var :apart_y, 0
      met = var :met, 0
      before_x = var :before_x, 0
      before_y = var :before_y, 0
      enemies.func(:step_straight) do |e|
        before_x = e.place_x
        before_y = e.place_y
        if e.dir == 0 || e.dir == 2
          middle = ((e.place_y >> 8) & 0xFFF0) + 8
          e.place_y += 256 if (e.place_y >> 8) < middle
          e.place_y -= 256 if (e.place_y >> 8) > middle
        end
        e.place_x = (e.place_x + step_x[e.dir]) & 0xFFFF
        e.place_y = (e.place_y + step_y[e.dir]) & 0xFFFF
        met = 0
        enemies.each do |other|
          if other.index != e.index
            apart_x = (other.place_x >> 8) - (e.place_x >> 8)
            apart_x = apart_x.abs
            apart_y = (other.place_y >> 8) - (e.place_y >> 8)
            apart_y = apart_y.abs
            met = 1 if apart_x < 16 && apart_y < 16
          end
        end
        if met == 1
          e.place_x = before_x
          e.place_y = before_y
          e.dir = (e.dir + 2) & 3
        end
      end
      game_loop do
        enemies.each { |_enemy| call :step_straight }
      end
    end
  end

  # The retail game's walk of five enemies (Super Bomberman's straight_movement and the collision
  # checks it calls, bank6.asm) is about a fifteenth of a frame, measured in bsnes by the processor
  # time spent at each of its routines' addresses. A pair checked costs what the console's own game
  # spends; what each thing costs besides (the walk's set-up and wind-down, the step by the table)
  # is still more, so the bound holds what the routine costs now, under a tenth, until those come
  # down too.
  def test_five_walkers_stepping_and_checking_take_under_a_tenth_of_a_frame
    rom = self.class.game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }

    assert_operator spent.share, :<, 0.1
  end

  # The walkers step, meet and turn as on the interpreter, on every pass.
  def test_the_walkers_are_the_interpreters_on_every_pass
    game_player.run(self.class.game.program(console: :snes), frames: 60)
  end
end
