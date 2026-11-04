# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/cube3d").to_s

# The flight the Cube 3D example's tests fly, kept once for this file and the test of the
# Advance's cartridge (test/lowering/gba/examples/test_cube3d_example_cartridge.rb).
module Cube3DFlight
  # A flight round the crate, the buttons held on each frame from the first: closer, round to
  # the left a little, tipped up, rolled, and back out.
  def self.buttons(frame)
    case frame
    when 1..20 then %i[a]
    when 21..40 then %i[right a]
    when 41..55 then %i[up]
    when 56..70 then %i[l b]
    when 71..90 then %i[left down]
    else []
    end
  end
end

# The Cube 3D example (examples/cube3d.rb): a crate seen from a viewer the player flies, on every
# run that plays games as the Advance.
class TestCube3DExample < Minitest::Test
  SPACE = VBlank::Testing.shown(0x2842) # rgb(2, 2, 10), the space round the crate

  # Four wholes back from the crate, its near side, two wholes across and three away, covers
  # the middle third of the screen across: pixels 80 to 159.
  def test_the_crate_is_in_the_middle_of_the_view_at_the_start
    screen = game_player.run(Cube3D.program, frames: 3).screen

    refute_equal SPACE, screen.pixel(120, 80)
    refute_equal SPACE, screen.pixel(85, 45)
    assert_equal SPACE, screen.pixel(70, 80)
    assert_equal SPACE, screen.pixel(170, 80)
  end

  # A whole closer, the near side is two away and covers the middle half: pixels 60 to 179.
  def test_flying_ahead_brings_the_crate_closer
    screen = game_player.hold(:a).run(Cube3D.program, frames: 23).screen

    refute_equal SPACE, screen.pixel(70, 80)
    assert_equal SPACE, screen.pixel(50, 80)
  end

  # A quarter turn to the left puts the crate beside the viewer, out of the view.
  def test_turning_away_leaves_only_space
    screen = game_player.hold(:left).run(Cube3D.program, frames: 48).screen

    [[120, 80], [10, 10], [230, 150]].each { |x, y| assert_equal SPACE, screen.pixel(x, y) }
  end

  # The whole flight, every pass: on a run that builds the game, every frame is checked against
  # the interpreter.
  def test_a_flight_round_the_crate
    played = game_player.input_each_frame { |frame| Cube3DFlight.buttons(frame) }.run(Cube3D.program, frames: 100)

    assert played
  end
end
