# frozen_string_literal: true

require "test_helper"
require "stringio"

# A walk of twenty-four things, and their fields moved on: what the walk's own step costs a thing,
# with nothing in its body, and what each `thing.field += 1` in the body adds. The profiler reads
# the part of the frame the console was awake against the same game with no walk.
class TestGBAPoolWalkStepCost < Minitest::Test
  # A frame's processor cycles: 228 lines of 1232.
  FRAME_CYCLES = 228 * 1232

  # The game: twenty-four things, walked every pass where +walked+, each with +fields+ of its three
  # fields moved on by one; each thing a sprite where +drawn+.
  def self.game(fields, walked: true, drawn: false)
    VBlank.game("STEP #{fields}", consoles: %i[gba]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      sprite_fields = drawn ? { x: 0, y: 0, image: :floor } : {}
      things = pool :thing, a: 0, b: 0, c: 0, capacity: 24, **sprite_fields
      24.times { things.spawn(a: 1, b: 2, c: 3) }
      game_loop do
        if walked
          things.each do |t|
            t.a += 1 if fields >= 1
            t.b += 1 if fields >= 2
            t.c += 1 if fields >= 3
          end
        end
      end
    end
  end

  private def game_cycles(game)
    rom = game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false)
    (1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share) * FRAME_CYCLES
  end

  # An ARM game steps to the next record with an ADD, its count and a branch, about 10 cycles, and
  # moves a field on with an LDR, an ADD and an STR at an offset from a register on the record,
  # about 6 (GBATEK, "ARM CPU Instruction Cycle Times"). Kept as lists the step was 56 cycles a thing
  # and a field 32; kept as records, r10 held on the thing (GBA::Statements#emit_stepped_walk), 4
  # and 5.
  def test_a_walk_step_costs_under_15_cycles_a_thing_and_a_field_under_10
    none = game_cycles(self.class.game(0, walked: false))
    empty = game_cycles(self.class.game(0))
    three = game_cycles(self.class.game(3))

    assert_operator (empty - none) / 24, :<, 15
    assert_operator (three - empty) / 72, :<, 10
  end

  # The same with each thing a sprite, whose pool is kept the same way: its sprites show copies of
  # the fields, made once a frame, so the walk reaches its fields as any pool's does. Kept as lists
  # the step was 54 cycles a thing and a field 30; as records, 2 and 4.
  def test_a_walk_of_sprites_steps_as_cheaply
    none = game_cycles(self.class.game(0, walked: false, drawn: true))
    empty = game_cycles(self.class.game(0, drawn: true))
    three = game_cycles(self.class.game(3, drawn: true))

    assert_operator (empty - none) / 24, :<, 15
    assert_operator (three - empty) / 72, :<, 10
  end
end
