# frozen_string_literal: true

require "test_helper"
require "stringio"

# ONE THING OF A POOL CHECKED AGAINST ANOTHER, as enemies that turn back when they meet do every
# frame: a routine of the pool walks the pool, and for each other thing tests how far apart the two
# are on each axis, `(other.x - e.x).abs < 16`. What one more thing to check costs is the walk's turn
# for it and the test of its x. The routine runs for one thing, against two others and then four,
# and the profiler reads the routine's share of the time. Every other is far off in x, so no y is
# tested.
class TestGBCPoolPairCheckCost < Minitest::Test
  PLACES = [[40, 40], [120, 72], [72, 120], [160, 100], [200, 30]].freeze

  # The places kept in half words.
  HALF_PLACES = { place_x: :half, place_y: :half }.freeze

  # The game with +others+ things besides the one the routine runs for, its fields as wide as
  # +widths+ says.
  def self.game(others, widths: {})
    places = PLACES.first(others + 1)
    VBlank.game("PAIRS #{others}", consoles: %i[gbc]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      enemies = pool :enemy, place_x: 0, place_y: 0, near: 0, capacity: 8, widths: widths
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

  # A frame's processor cycles at the double speed the build runs at.
  FRAME_CYCLES = 140_448

  private def routine_cycles(game)
    rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }
    spent.share * FRAME_CYCLES
  end

  # The console's own object update (Pokemon Pinball's UpdateSeelPosition, pret/pokepinball,
  # seel_bonus_resolve_collision.asm) is called with HL and DE into the seel's record: its call and
  # state check about 116 cycles, a 16-bit field add about 56. Kept as lists, one more pair cost
  # 932 cycles here: each field read checked the index, scaled it and added the list's place, and
  # the walk stepped through variables. Kept as tables and walked by the thing's distance, each
  # field HL set from it (Backends::PoolLayout::Tables, GBC::Lowering#emit_stepped_walk), 604; the
  # rest is the test's 32-bit difference, worked out a byte at a time.
  def test_one_more_thing_to_check_costs_under_650_cycles
    per_pair = (routine_cycles(self.class.game(4)) - routine_cycles(self.class.game(2))) / 2

    assert_operator per_pair, :<, 650
  end

  # With the places in half words: the test still works the difference out in 32 bits.
  def test_one_more_thing_to_check_in_half_words_costs_under_650_cycles
    halves = ->(others) { self.class.game(others, widths: HALF_PLACES) }
    per_pair = (routine_cycles(halves.call(4)) - routine_cycles(halves.call(2))) / 2

    assert_operator per_pair, :<, 650
  end

  # The checks find what the interpreter finds on every pass, the meeting included.
  def test_the_checks_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(4).program(console: :gbc), frames: 20)
  end
end
