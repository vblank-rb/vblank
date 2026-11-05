# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/two_rooms").to_s

# The Two Rooms example (examples/two_rooms.rb) on every run that plays games as the PlayStation: a
# game that works out which of its rooms it can see through a doorway and draws only those, laid out
# for the PlayStation's screen, 320 by 240. On the PlayStation's own run every pass is checked against
# the interpreter, every pixel with none let off: the far room is held to the window the doorway's
# corners give (`screen_spot`), and the two must meet at the doorway's edges to the pixel. The
# Advance's twin is test/console/gba/examples/test_two_rooms_example.rb.
class TestTwoRoomsExampleOnThePlayStation < Minitest::Test
  BRICK = [[14, 12, 10], [24, 8, 4]].map { |r, g, b| VBlank::Testing.shown(r | (g << 5) | (b << 10)) }

  # The Advance's flight: through the doorway and on into the brick room, a little turn on the way,
  # then round to look back at the doorway.
  private def buttons(frame)
    case frame
    when 1..25 then %i[a]
    when 26..32 then %i[a left]
    when 33..45 then %i[a right]
    when 46..60 then %i[a]
    when 61..150 then %i[left]
    else []
    end
  end

  private def program = TwoRooms::GAME.program(console: game_console)

  # Two wholes ahead, the doorway runs from half a whole left to half right, and from half a whole up
  # to the floor a whole down: 40 pixels a half whole on a screen 320 across, so x 120 to 200 and y 80
  # to 200.
  def test_the_brick_room_is_seen_through_the_doorway_at_the_start
    played = game_player.run(program, frames: 3)

    assert_equal [120, 80, 200, 200], %i[left top right bottom].map { |edge| played[edge] }
    assert_equal 2, played[:rooms_drawn]
    assert_includes BRICK, played.screen.pixel(160, 120), "the brick room's far wall, through the doorway"
  end

  # The whole flight, every pass checked. A pass drawing faces close up takes the PlayStation several
  # frames, so the flight ends wherever that many frames' passes take it.
  def test_a_flight_through_the_doorway_and_back_round
    played = game_player.input_each_frame { |frame| buttons(frame) }.run(program, frames: 150)

    assert played
  end

  # Two wholes on, through the doorway, the viewer is in the brick room, and stays there flying on
  # (its far wall is six wholes on): it takes forty passes, which 250 frames hold however long the
  # passes on the way take, up to six frames each.
  def test_flying_through_the_doorway_puts_the_viewer_in_the_brick_room
    played = game_player.hold(:a).run(program, frames: 250)

    assert_equal TwoRooms::BRICK, played[:here]
    assert_equal 1, played[:rooms_drawn]
  end
end
