# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/cube3d").to_s

# The Cube 3D example (examples/cube3d.rb) on every run that plays games as the PlayStation: a crate
# seen from a viewer the player flies, laid out for the PlayStation's screen, 320 by 240. On the
# PlayStation's own run every pass is checked against the interpreter, every pixel with none let off.
# The Advance's twin is test/console/gba/examples/test_cube3d_example.rb.
class TestCube3DExampleOnThePlayStation < Minitest::Test
  SPACE = VBlank::Testing.shown(0x2842) # rgb(2, 2, 10), the space round the crate

  # The flight the Advance's test flies: closer, round to the left a little, tipped up, rolled, and
  # back out.
  private def buttons(frame)
    case frame
    when 1..20 then %i[a]
    when 21..40 then %i[right a]
    when 41..55 then %i[up]
    when 56..70 then %i[l b]
    when 71..90 then %i[left down]
    else []
    end
  end

  private def program = Cube3D::GAME.program(console: game_console)

  # Four wholes back from the crate, its near side, two wholes across and three away, covers the
  # middle third of the screen across: pixels 107 to 213 of 320.
  def test_the_crate_is_in_the_middle_of_the_view_at_the_start
    screen = game_player.run(program, frames: 3).screen

    refute_equal SPACE, screen.pixel(160, 120)
    refute_equal SPACE, screen.pixel(110, 70)
    assert_equal SPACE, screen.pixel(100, 120)
    assert_equal SPACE, screen.pixel(220, 120)
  end

  def test_a_flight_round_the_crate
    played = game_player.input_each_frame { |frame| buttons(frame) }.run(program, frames: 100)

    assert played
  end
end
