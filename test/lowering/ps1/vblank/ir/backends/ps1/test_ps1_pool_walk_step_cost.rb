# frozen_string_literal: true

require "test_helper"
require "stringio"

# A walk of twenty-four things, and their fields moved on: what the walk's own step costs a thing,
# with nothing in its body, and what each `thing.field += 1` in the body adds. The profiler reads
# the game's share against the same game with no walk.
class TestPS1PoolWalkStepCost < Minitest::Test
  # A frame's processor cycles.
  FRAME_CYCLES = 566_122

  # The game: twenty-four things, walked every pass where +walked+, each with +fields+ of its three
  # fields moved on by one; each thing a sprite where +drawn+.
  def self.game(fields, walked: true, drawn: false)
    VBlank.game("STEP #{fields}", consoles: %i[ps1]) do
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
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 30).game.sum(&:share) * FRAME_CYCLES
  end

  # An R3000 game steps to the next record with an add and the loop's branch, about ten cycles, and
  # moves a field on with a load, an add and a store at a distance from a register on the record,
  # about eight to ten, the load from main RAM, which has no data cache, the dearest (psx-spx, "CPU
  # Load/Store Opcodes", "Memory Control"). Kept as lists the step was 54 cycles a thing and a field
  # 25; kept as tables, s7 held on the thing (PS1::Lowering#emit_stepped_walk), 15 and 11, the next
  # thing's link a load from main RAM each turn.
  def test_a_walk_step_costs_under_20_cycles_a_thing_and_a_field_under_14
    none = game_cycles(self.class.game(0, walked: false))
    empty = game_cycles(self.class.game(0))
    three = game_cycles(self.class.game(3))

    assert_operator (empty - none) / 24, :<, 20
    assert_operator (three - empty) / 72, :<, 14
  end

  # The same with each thing a sprite, whose pool is kept the same way: its sprites show copies of
  # the fields, made once a frame, so the walk reaches its fields as any pool's does. Kept as lists
  # the step was 57 cycles a thing and a field 25; as tables, 17 and 11.
  def test_a_walk_of_sprites_steps_as_cheaply
    none = game_cycles(self.class.game(0, walked: false, drawn: true))
    empty = game_cycles(self.class.game(0, drawn: true))
    three = game_cycles(self.class.game(3, drawn: true))

    assert_operator (empty - none) / 24, :<, 20
    assert_operator (three - empty) / 72, :<, 14
  end

  # The fields move on as on the interpreter, on every pass.
  def test_the_fields_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(3).program(console: :ps1), frames: 20)
  end
end
