# frozen_string_literal: true

require "test_helper"
require "stringio"

# A WALK OF TWENTY-FOUR THINGS, AND THEIR FIELDS MOVED ON: what the walk's own step costs a thing,
# with nothing in its body, and what each `thing.field += 1` in the body adds. The profiler reads
# the game's share against the same game with no walk.
class TestGBCPoolWalkStepCost < Minitest::Test
  # A frame's processor cycles at the double speed the build runs at.
  FRAME_CYCLES = 140_448

  # The game: twenty-four things, walked every pass where +walked+, each with +fields+ of its three
  # fields moved on by one.
  def self.game(fields, walked: true)
    VBlank.game("STEP #{fields}", consoles: %i[gbc]) do
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
    rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 30).game.sum(&:share) * FRAME_CYCLES
  end

  # The console's own object update (Pokemon Pinball's UpdateSeelPosition, pret/pokepinball,
  # seel_bonus_resolve_collision.asm) is called for each seel with HL and DE into its record: the call
  # and its state check about 116 cycles, a 16-bit field add about 56, a byte field's INC 24. Kept as
  # lists the step was 465 cycles a thing and a field about 370; kept as tables, the walk keeping the
  # thing's distance and each field HL set from it (GBC::Lowering#emit_stepped_walk), and a field
  # moved on where it is, a byte at a time only as far as the carry goes
  # (GBC::Lowering#emit_held_field_nudged), 156 and 72.
  def test_a_walk_step_costs_under_170_cycles_a_thing_and_a_field_under_80
    none = game_cycles(self.class.game(0, walked: false))
    empty = game_cycles(self.class.game(0))
    three = game_cycles(self.class.game(3))

    assert_operator (empty - none) / 24, :<, 170
    assert_operator (three - empty) / 72, :<, 80
  end

  # The fields move on as on the interpreter, on every pass.
  def test_the_fields_are_the_interpreters_on_every_pass
    game_player.run(self.class.game(3).program(console: :gbc), frames: 20)
  end
end
