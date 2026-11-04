# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/two_rooms").to_s

# The flight the Two Rooms example's tests fly, kept once for this file and the test of the
# Advance's cartridge (test/lowering/gba/examples/test_two_rooms_example_cartridge.rb).
module TwoRoomsFlight
  # Through the doorway and on into the brick room, a little turn on the way, then round to look
  # back at the doorway.
  def self.buttons(frame)
    case frame
    when 1..25 then %i[a]
    when 26..32 then %i[a left]
    when 33..45 then %i[a right]
    when 46..60 then %i[a]
    when 61..150 then %i[left]
    else []
    end
  end

  def self.colors(*rgbs) = rgbs.map { |r, g, b| VBlank::Testing.shown(r | (g << 5) | (b << 10)) }
end

# The Two Rooms example (examples/two_rooms.rb): a game that works out which of its rooms it can
# see through a doorway and draws only those, on every run that plays games as the Advance.
class TestTwoRoomsExample < Minitest::Test
  STONE = TwoRoomsFlight.colors([8, 8, 9], [20, 20, 22])
  BRICK = TwoRoomsFlight.colors([14, 12, 10], [24, 8, 4])
  GROUND = TwoRoomsFlight.colors([6, 10, 4], [10, 16, 6])

  # Two wholes ahead, the doorway runs from half a whole left to half right, and from half a whole
  # up to the floor a whole down: 30 pixels a half whole, so x 90 to 150 and y 50 to 140.
  def test_the_brick_room_is_seen_through_the_doorway_at_the_start
    played = game_player.run(TwoRooms.program, frames: 3)

    assert_equal [90, 50, 150, 140], %i[left top right bottom].map { |edge| played[edge] }
    assert_equal 2, played[:rooms_drawn]
    assert_includes BRICK, played.screen.pixel(120, 80), "the brick room's far wall, through the doorway"
    assert_includes GROUND, played.screen.pixel(120, 125), "the brick room's floor"
    assert_includes STONE, played.screen.pixel(60, 80), "the stone wall beside the doorway"
    assert_includes STONE, played.screen.pixel(120, 40), "the stone wall over the doorway"
  end

  # Half a turn round, the doorway is behind the viewer and the brick room is not drawn.
  def test_with_the_doorway_behind_only_the_stone_room_is_drawn
    played = game_player.hold(:left).run(TwoRooms.program, frames: 93)

    assert_equal 1, played[:rooms_drawn]
    assert_includes STONE, played.screen.pixel(120, 80)
  end

  # Three wholes on, the viewer stands in the brick room, looking at its far wall.
  def test_flying_through_the_doorway_puts_the_viewer_in_the_brick_room
    played = game_player.hold(:a).run(TwoRooms.program, frames: 63)

    assert_equal TwoRooms::BRICK, played[:here]
    assert_equal 1, played[:rooms_drawn]
    assert_includes BRICK, played.screen.pixel(120, 80)
  end

  # The whole flight, every pass: on a run that builds the game, every frame is checked against
  # the interpreter.
  def test_a_flight_through_the_doorway_and_back_round
    played = game_player.input_each_frame { |frame| TwoRoomsFlight.buttons(frame) }.run(TwoRooms.program, frames: 160)

    assert_equal TwoRooms::BRICK, played[:here]
    assert_equal 2, played[:rooms_drawn], "looking back, the stone room is seen through the doorway"
  end
end
