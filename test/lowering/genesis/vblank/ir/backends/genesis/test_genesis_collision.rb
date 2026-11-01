# frozen_string_literal: true

require "test_helper"

# Whether two sprites' drawn pixels touch (`overlaps?` without a `hitbox:`), played on a Genesis cartridge
# and the interpreter together (Genesis::CheckedRun): the answer is read every pass, so a mask read from the
# wrong place, a box edge out by one, or a pose counted wrong shows as the pass it first disagrees on.
class TestGenesisCollision < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  RING = <<~ART
    ########
    #......#
    #......#
    #......#
    #......#
    #......#
    #......#
    ########
  ART

  def test_a_dot_walking_through_a_ring_touches_it_only_where_the_ring_is_drawn
    program = program_of do
      screen :tiled
      image(:ring, "." => :transparent, "#" => :white) { RING }
      image(:dot, "#" => :red) { "##\n##" }
      ring = sprite :ring, at: [60, 60]
      dot = sprite :dot, at: [54, 62]
      touches = 0
      misses = 0
      game_loop do
        dot.move :right, by: 1
        if ring.overlaps?(dot)
          touches += 1
        else
          misses += 1
        end
      end
    end
    run = Genesis::CheckedRun.new.run(program, frames: 24)

    assert_operator run[:touches], :>, 0, "the dot reaches the ring's wall"
    assert_operator run[:misses], :>, 0, "and is inside the ring's empty middle for a while"
  end

  def test_two_poses_of_different_widths_are_each_read_as_drawn
    program = program_of do
      screen :tiled
      image(:wide, "." => :transparent, "#" => :white) { "########\n########" }
      image(:narrow, "." => :transparent, "#" => :white) { "##......\n##......" }
      image(:pin, "#" => :red) { "##\n##" }
      bar = sprite :bar, at: [100, 20], facing: { right: :wide, left: :narrow }
      pin = sprite :pin, at: [106, 20]
      reached = 0
      steps = 0
      game_loop do
        steps += 1
        bar.face(:left) if steps > 5
        reached += 1 if bar.overlaps?(pin)
      end
    end
    run = Genesis::CheckedRun.new.run(program, frames: 10)

    assert_equal 5, run[:reached], "wide for five passes, then narrow, which does not reach the pin"
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
