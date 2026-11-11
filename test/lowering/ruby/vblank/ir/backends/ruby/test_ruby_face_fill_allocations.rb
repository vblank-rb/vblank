# frozen_string_literal: true

require "test_helper"
require "place_games"

# A game built as Ruby fills a 3D face a pixel at a time in Ruby, and an object made for each pixel is
# one the garbage collector then clears away: a game of a few thousand faces spent most of
# its time doing that. So what the fill works out for each pixel is kept in plain numbers, and the
# arrays it makes are a few to a row and to a stretch of perspective. The picture is held to the
# interpreter's by the place tests this run plays; this is only the count.
class TestRubyFaceFillAllocations < Minitest::Test
  # The square face of PlaceGames.lit_square covers x 60 to 179 and y 20 to 139.
  FACE_PIXELS = 120 * 120

  private def objects_made_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    before = GC.stat(:total_allocated_objects)
    game.play(player)
    GC.stat(:total_allocated_objects) - before
  end

  # The objects one more pass makes, with what starting the game makes taken away.
  private def objects_a_pass(program)
    (objects_made_playing(program, 12) - objects_made_playing(program, 2)) / 10
  end

  def test_a_face_in_perspective_makes_far_fewer_objects_than_it_fills_pixels
    program = PlaceGames.lit_square(left: 1.0, right: 0.25, perspective: :every_8_pixels, far: 3.0)

    assert_operator objects_a_pass(program), :<, FACE_PIXELS / 2
  end

  def test_a_face_in_perspective_at_every_pixel_makes_fewer_objects_than_it_fills_pixels
    program = PlaceGames.lit_square(left: 1.0, right: 0.25, perspective: :every_pixel, far: 3.0)

    assert_operator objects_a_pass(program), :<, FACE_PIXELS
  end
end
