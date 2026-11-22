# frozen_string_literal: true

require "test_helper"

# A variable stepped up and back down by the same number, with nothing between that can see it,
# is left as it is (SNES::Lowering#cancelled_steps), as a pool's count of walks under way is around
# a walk that removes nothing. Where what is between can stop the game, the interpreter stops with
# the variable stepped up, so the steps are made.
class TestSNESStepPairs < Minitest::Test
  Build = VBlank::IR::Build

  # The bytes of code the Super Nintendo build makes for a game running +statements+ once, then
  # reading and stepping the variable, so it is a changing number in every game measured.
  private def code_bytes(statements)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      var :steps, 0
      var :other, 0
    end
    [*statements, Build.set(:other, Build.var_ref(:steps)), Build.add(:steps, Build.int(1))].each do |node|
      builder.record_statement(node)
    end
    builder.instance_eval { game_loop { wait_vblank } }
    builder.finalize_program
    VBlank::IR::Backends::SNES.new.build(builder.program).built.bytes.fetch(:code)
  end

  private def stepped_around(node) = [Build.add(:steps, Build.int(1)), node, Build.sub(:steps, Build.int(1))]

  def test_steps_around_a_variable_written_are_left_out
    written = -> { Build.set(:other, Build.int(3)) }

    assert_equal code_bytes([written.call]), code_bytes(stepped_around(written.call))
  end

  def test_steps_around_a_verb_that_can_stop_the_game_are_made
    scroll = -> { Build.scroll_background(:field, x: Build.int(1), y: Build.int(0)) }

    assert_operator code_bytes(stepped_around(scroll.call)), :>, code_bytes([scroll.call])
  end
end
