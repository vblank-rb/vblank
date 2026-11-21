# frozen_string_literal: true

require "test_helper"
require "stringio"

# One thing of a pool checked against another, as enemies that turn back when they meet do every
# frame: a routine of the pool walks the pool, and for each other thing tests how far apart the two
# are on each axis, `(other.x - e.x).abs < 16`. What one more thing to check costs is the walk's turn
# for it and the test of its x. The routine runs for one thing, against two others and then four,
# and the profiler reads the routine's share of the time. Every other is far off in x, so no y is
# tested.
class TestPS1PoolPairCheckCost < Minitest::Test
  PLACES = [[40, 40], [120, 72], [72, 120], [160, 100], [200, 30]].freeze

  # The places kept in half words.
  HALF_PLACES = { place_x: :half, place_y: :half }.freeze

  # The game with +others+ things besides the one the routine runs for, its fields as wide as
  # +widths+ says.
  def self.game(others, widths: {})
    places = PLACES.first(others + 1)
    VBlank.game("PAIRS #{others}", consoles: %i[ps1]) do
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

  # A frame's processor cycles.
  FRAME_CYCLES = 566_122

  private def routine_cycles(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    spent = rom.profile(out: StringIO.new, settle: 10, frames: 20).game.find { |row| row.routine.to_s.include?("step_straight") }
    spent.share * FRAME_CYCLES
  end

  # An R3000 game holds a register on a thing's record: a field is one load or store at a 16-bit
  # distance from it, and stepping on is an add with the loop's branch, about ten cycles (psx-spx,
  # "CPU Load/Store Opcodes"). Kept as lists, one more pair cost 96 cycles here: each field's index
  # checked, shifted and added to its list's place, and the walk stepping through variables. Kept as
  # tables and walked with s7 on the thing (Backends::PoolLayout::Tables,
  # PS1::Lowering#emit_stepped_walk), 51.
  def test_one_more_thing_to_check_costs_under_65_cycles
    per_pair = (routine_cycles(self.class.game(4)) - routine_cycles(self.class.game(2))) / 2

    assert_operator per_pair, :<, 65
  end

  # With the places in half words, an LH where a word is an LW: no dearer.
  def test_one_more_thing_to_check_in_half_words_costs_under_65_cycles
    halves = ->(others) { self.class.game(others, widths: HALF_PLACES) }
    per_pair = (routine_cycles(halves.call(4)) - routine_cycles(halves.call(2))) / 2

    assert_operator per_pair, :<, 65
  end

  # The checks find what the interpreter finds on every pass, the meeting included.
  def test_the_checks_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(4).program(console: :ps1), frames: 20)
  end
end
