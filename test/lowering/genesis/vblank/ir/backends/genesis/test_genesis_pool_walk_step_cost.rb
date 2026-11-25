# frozen_string_literal: true

require "test_helper"
require "stringio"

# A walk of twenty-four things, and their fields moved on: what the walk's own step costs a thing,
# with nothing in its body, and what each `thing.field += 1` in the body adds. The profiler reads
# the game's share against the same game with no walk.
class TestGenesisPoolWalkStepCost < Minitest::Test
  # A frame's 68000 cycles: 262 lines of 488.
  FRAME_CYCLES = 262 * 488

  # The game: twenty-four things, walked every pass where +walked+, each with +fields+ of its three
  # fields moved on by one.
  def self.game(fields, walked: true)
    VBlank.game("STEP #{fields}", consoles: %i[genesis]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      things = pool :thing, a: 0, b: 0, c: 0, capacity: 24
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
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 30).game.sum(&:share) * FRAME_CYCLES
  end

  # The console's own walk (Mean Bean Machine's RunActors, drmbm.asm) passes an empty slot in about
  # 52 cycles and moves a field on with one ADDQ.W on the actor's record, 16. Kept as lists the step
  # was 325 cycles a thing and a field 116; kept as tables, the walk holding A4 on the thing
  # (Genesis::Lowering#emit_stepped_walk) and the field moved on where it is
  # (Genesis::Lowering#emit_held_field_stepped), 57 and 24, a long's ADDQ being 24 where a word's is 16.
  def test_a_walk_step_costs_under_70_cycles_a_thing_and_a_field_under_30
    none = game_cycles(self.class.game(0, walked: false))
    empty = game_cycles(self.class.game(0))
    three = game_cycles(self.class.game(3))

    assert_operator (empty - none) / 24, :<, 70
    assert_operator (three - empty) / 72, :<, 30
  end

  # The fields move on as on the interpreter, on every pass.
  def test_the_fields_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(3).program(console: :genesis), frames: 20)
  end
end
