# frozen_string_literal: true

require "test_helper"

# Things of a pool walking a maze of 16-pixel squares, each checked against every other thing by a
# routine of the pool, as in test_snes_pool_place_walk_cost.rb, but laid out so that most never
# meet: a thing far from every other must walk on, never put back nor turned, and a random number is
# drawn only for a meeting. Played on the Super Nintendo and held to the interpreter on every pass.
#
# The routine is called from another of the pool's routines, the distances are kept in variables
# another routine also writes whole numbers to, and the slots are taken out of order, so the walk's
# pair check is played with its own thing's place kept before the walk, through each of the ways a
# distance and a slot can be held.
class TestSNESPoolWalkFalseMeetings < Minitest::Test
  # Every thing far from the others for the whole run.
  APART = [[[120, 56], 0], [[24, 24], 1], [[88, 152], 2], [[200, 120], 3], [[200, 24], 1]].freeze

  # Two that meet within a few passes, the rest far from them and from each other.
  SOME_MEET = [[[120, 56], 0], [[40, 100], 0], [[88, 152], 2], [[64, 100], 2], [[200, 24], 1]].freeze

  def self.game(layout)
    VBlank.game("FALSE MEETINGS", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      enemies = pool :enemy, place_x: 0, place_y: 0, dir: 0, capacity: 8,
                             widths: { place_x: :unsigned_half, place_y: :unsigned_half, dir: :byte }
      # A stage before this one: its things spawned and removed, so this stage's take slots out of
      # order and the chain does not run in slot order.
      7.times { |i| enemies.spawn(place_x: 4000 * i, place_y: 0, dir: 0) }
      enemies.each { |old| old.remove }
      layout.each { |(x, y), dir| enemies.spawn(place_x: x * 256, place_y: (y * 256) + 128, dir: dir) }
      step_x = table :step_x, [96, 0, -96, 0], width: :half
      step_y = table :step_y, [0, 96, 0, -96], width: :half
      apart_x = var :apart_x, 0
      apart_y = var :apart_y, 0
      met = var :met, false
      mover = var :mover, 0
      turns = var :turns, 0
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
        met = false
        mover = e.index
        enemies.each do |other|
          if other.index != mover
            apart_x = (other.place_x >> 8) - (e.place_x >> 8)
            apart_x = -apart_x if apart_x < 0
            apart_y = (other.place_y >> 8) - (e.place_y >> 8)
            apart_y = -apart_y if apart_y < 0
            met = true if apart_x < 16 && apart_y < 16
          end
        end
        if met
          e.place_x = before_x
          e.place_y = before_y
          e.dir = (e.dir + 2) & 3
          turns += 1
        end
      end
      # A distance kept whole, as one from a place far off the screen needs.
      far = var :far, 0
      func(:touch) do
        apart_x = far - 40
        far += 70_000
      end
      ahead_x = var :ahead_x, 0
      enemies.func(:test_ahead) do |e|
        ahead_x = (e.place_x >> 8) + 16
      end
      enemies.func(:wander) do |_e|
        call :test_ahead
        call :step_straight
      end
      game_loop do
        call :touch
        enemies.each { |_enemy| call :wander }
      end
    end
  end

  def test_things_far_apart_never_meet_as_on_the_interpreter
    run = game_player.run(self.class.game(APART).program(console: :snes), frames: 40)

    assert_equal 0, run[:turns]
  end

  def test_only_the_things_that_meet_turn_as_on_the_interpreter
    run = game_player.run(self.class.game(SOME_MEET).program(console: :snes), frames: 40)

    assert_operator run[:turns], :>, 0
  end
end
