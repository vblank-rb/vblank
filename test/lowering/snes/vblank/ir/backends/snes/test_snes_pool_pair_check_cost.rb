# frozen_string_literal: true

require "test_helper"
require "stringio"

# ONE THING OF A POOL CHECKED AGAINST ANOTHER, as enemies that turn back when they meet do every
# frame: a routine of the pool walks the pool, and for each other thing tests how far apart the two
# are on each axis, `(other.x - e.x).abs < 16`. What one more thing to check costs is the walk's turn
# for it and the test of its x: the fields read where they are, at X, the loop's count kept in its
# low half (SNES::Lowering#with_counter_held), the next thing's link stored straight from its slot,
# and the two slots compared by their low halves.
#
# The routine runs for one thing, against two others and then four, and the profiler reads the
# routine's share of the time. Every other is far off in x, so no y is tested.
class TestSNESPoolPairCheckCost < Minitest::Test
  PLACES = [[40, 40], [120, 72], [72, 120], [160, 100], [200, 30]].freeze

  # The game with +others+ things besides the one the routine runs for.
  def self.game(others)
    places = PLACES.first(others + 1)
    VBlank.game("PAIRS #{others}", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      enemies = pool :enemy, place_x: 0, place_y: 0, near: 0, capacity: 8
      places.each { |x, y| enemies.spawn(place_x: x, place_y: y) }
      bumped = var :bumped, 0
      enemies.func(:step_straight) do |e|
        bumped = 0
        enemies.each do |other|
          bumped = 1 if other.index != e.index && (other.place_x - e.place_x).abs < 16 && (other.place_y - e.place_y).abs < 16
        end
        e.near = bumped
      end
      game_loop do
        enemies.each { |t| call :step_straight if t.place_x == 40 }
      end
    end
  end

  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  private def routine_clocks(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }
    spent.share * FRAME_CLOCKS
  end

  # The retail game's walk (Super Bomberman's check_for_enemy_with_enemy_collision) spends about 372
  # master clocks on an enemy whose x it tests, in 8 bits with the object in X. Ours keeps every
  # number in 32 bits; the bound holds the cheaper turn and test: short branches where the target is
  # near (W65816#branch_long), the walk's slot copies a half long, and `abs(d) < 16` decided from
  # d's high half (SNES::Lowering#compare_absolute_below).
  def test_one_more_thing_to_check_costs_under_1470_master_clocks
    per_pair = (routine_clocks(self.class.game(4)) - routine_clocks(self.class.game(2))) / 2

    assert_operator per_pair, :<, 1470
  end

  # The checks find what the interpreter finds on every pass, the meeting included.
  def test_the_checks_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(4).program(console: :snes), frames: 20)
  end
end
