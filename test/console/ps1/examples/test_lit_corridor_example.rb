# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/lit_corridor").to_s

# The Lit Corridor example (examples/lit_corridor.rb) on every run that plays games as the PlayStation:
# a corridor lit from each face's corners through the game's shading, by a lamp that flickers, laid out
# for the PlayStation's screen, 320 by 240. On the PlayStation's own run every pass is checked against
# the interpreter, every pixel with none let off. The Advance's twin is
# test/console/gba/examples/test_lit_corridor_example.rb.
class TestLitCorridorExampleOnThePlayStation < Minitest::Test
  # The left wall at the middle row: near the viewer, far from the lamp, then under it.
  NEAR_WALL = [10, 120].freeze
  UNDER_LAMP = [130, 120].freeze

  # The stone's mortar, as the picture has it: the colour the lamp shows at full light.
  MORTAR = VBlank::Testing.shown(8 | (8 << 5) | (9 << 10))

  private def program = LitCorridor::GAME.program(console: game_console)

  def test_the_wall_under_the_lamp_is_its_own_colour_and_the_wall_far_from_it_darker
    played = game_player.run(program, frames: 1)

    assert_equal 0, played[:flicker]
    assert_equal MORTAR, played.screen.pixel(*UNDER_LAMP)
    assert_operator brightness(played.screen.pixel(*NEAR_WALL)), :<, brightness(MORTAR)
  end

  # Now and then the lamp dims by a number the game rolls: the wall under it changes with it, and the
  # wall far from it does not.
  def test_the_lamp_flickers_and_the_far_wall_stays_as_it_is
    under = []
    near = []
    player = game_player
    player.each_vblank do
      under << player.screen.pixel(*UNDER_LAMP)
      near << player.screen.pixel(*NEAR_WALL)
    end
    player.run(program, frames: 40)

    assert_operator under.uniq.length, :>, 1, "the lamp never flickered"
    assert_equal 1, near.drop(2).uniq.length
  end

  # Down the corridor and round to the left, the lamp flickering: every pass checked.
  def test_a_flight_down_the_corridor
    played = game_player.input_each_frame { |frame| frame < 40 ? %i[a] : %i[a left] }.run(program, frames: 70)

    assert played
  end

  private def brightness(color) = (color & 31) + ((color >> 5) & 31) + ((color >> 10) & 31)
end
