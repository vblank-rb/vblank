# frozen_string_literal: true

require "test_helper"
require "place_games"

# A place made of flat faces, drawn as a viewer sees it, on every run that plays games as the
# PlayStation: the Advance's games (test/console/gba/vblank/builder/test_places_on_the_advance.rb).
# A game a test builds names no console, so it is laid out for the Advance's screen, and its place
# lands where it does there, at the top left of the PlayStation's bigger screen.
#
# On the PlayStation's own run every pass of every game is checked against the interpreter, every
# pixel with none let off, so the pixels asserted here are landmarks and the check is the rest.
class TestPlacesOnThePlayStation < Minitest::Test
  BLACK = VBlank::Testing.shown(:black)

  private def tile(across, down) = shown(PlaceGames.tile(across, down))

  # The landmarks inside the face are well inside a texel each: the PlayStation's graphics chip reads a
  # pixel's top-left corner half a texel on, where the interpreter reads its middle, so in the last
  # column and row of a picture stretched 15 times the chip has already reached the next repeat.
  def test_a_square_face_lands_where_the_view_says_with_its_picture_stretched_across
    screen = game_player.run(PlaceGames.square, frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(60, 20)
    assert_equal tile(7, 0), screen.pixel(170, 20)
    assert_equal tile(0, 7), screen.pixel(60, 130)
    assert_equal tile(7, 7), screen.pixel(170, 130)
    [[59, 20], [180, 20], [60, 19], [60, 140]].each do |x, y|
      assert_equal BLACK, screen.pixel(x, y), "(#{x}, #{y}) is outside the face"
    end
  end

  # A viewer turned by angles the game works out, one a pass (PlaceGames.spins, fractions and
  # whole degrees): the face's top left corner is drawn where screen_spot says it lands, pass
  # after pass.
  def test_a_viewer_turned_by_a_worked_out_angle_draws_the_face_where_its_corner_lands
    [false, true].product((2..8).to_a).each do |whole, frames|
      played = game_player.run(PlaceGames.turning_square(whole: whole), frames: frames)
      x = played[:x0]
      y = played[:y0]

      assert_equal tile(0, 0), played.screen.pixel(x + 2, y + 2), "inside the corner after #{played[:frame]} turns"
      assert_equal BLACK, played.screen.pixel(x - 2, y + 2), "left of the corner after #{played[:frame]} turns"
    end
  end

  def test_a_picture_repeats_past_its_edges_both_ways
    screen = game_player.run(PlaceGames.square(on_picture: [[-70, -70], [140, -70], [140, 140], [-70, 140]]),
                             frames: 2).screen

    assert_equal tile(2, 2), screen.pixel(60, 20), "-70 is 2 past a repeat at -72"
    assert_equal tile(2, 1), screen.pixel(60, 24), "-62.1 down is 1 past a repeat at -64"
  end

  # The picture repeated two thousand times each way across a narrow face, 30 pixels wide: every
  # square the face is cut into reaches thousands of texels across the picture, so it is cut on the
  # picture dozens of times each way, far more than the pieces that can wait at once. The checked run
  # holds every pixel to what those cuts send, so what the cutting keeps of one piece for the next
  # cannot run out.
  def test_a_picture_repeated_thousands_of_times_is_cut_on_the_picture_again_and_again
    on_picture = [[-8000, -8000], [8000, -8000], [8000, 8000], [-8000, 8000]]
    played = game_player.run(PlaceGames.square(on_picture: on_picture, x_scale: 0.25), frames: 2)

    assert((105...135).any? { |x| played.screen.pixel(x, 80) != BLACK }, "the face is drawn")
  end

  def test_a_face_wider_than_the_view_is_cut_at_its_edges
    screen = game_player.run(PlaceGames.square(x_scale: 3.0), frames: 2).screen

    assert_equal tile(1, 3), screen.pixel(0, 72)
    assert_equal tile(6, 3), screen.pixel(239, 72)
    assert_equal BLACK, screen.pixel(240, 72), "past the view the game was laid out for"
  end

  def test_a_face_half_behind_the_viewer_is_cut_at_the_near_limit
    screen = game_player.run(PlaceGames.floor, frames: 2).screen

    refute_equal BLACK, screen.pixel(120, 150)
    assert_equal BLACK, screen.pixel(120, 119)
  end

  def test_a_face_seen_from_behind_is_left_out_unless_both_sides_are_drawn
    behind = game_player.run(PlaceGames.square(turned_round: true), frames: 2).screen
    both = game_player.run(PlaceGames.square(turned_round: true, both_sides: true), frames: 2).screen

    assert_equal BLACK, behind.pixel(119, 79)
    assert_equal tile(0, 0), both.pixel(60, 20)
  end

  def test_a_face_as_far_behind_the_viewer_as_a_place_reaches_is_not_drawn
    screen = game_player.run(PlaceGames.far_behind, frames: 2).screen

    assert_equal BLACK, screen.pixel(119, 79)
  end

  # Five corners, moving edges, the picture changing and the perspective going from none to every
  # eight pixels to every pixel, pass by pass: every pass checked.
  def test_a_face_whose_edges_and_picture_change_every_pass
    screen = game_player.run(PlaceGames.moving_five_corners, frames: 8).screen

    refute_equal BLACK, screen.pixel(110, 60)
  end

  def test_a_lit_face_whose_edges_and_picture_change_every_pass
    screen = game_player.run(PlaceGames.moving_five_corners(lit: true), frames: 8).screen

    refute_equal BLACK, screen.pixel(110, 60)
  end

  def test_each_face_shows_its_own_picture_and_a_face_can_have_three_corners
    screen = game_player.run(PlaceGames.two_faces, frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105), "the triangle's left edge is red"
  end

  def test_a_picture_on_a_wall_leaning_away_in_each_perspective
    red = shown(0x001F)
    blue = shown(0x7C00)
    %i[every_8_pixels every_pixel].each do |perspective|
      screen = game_player.run(PlaceGames.wall_down_the_side(perspective), frames: 2).screen

      assert_equal red, screen.pixel(92, 80), "#{perspective}: x 92 is under six wholes ahead"
      assert_equal blue, screen.pixel(104, 80), "#{perspective}: x 104 is past six wholes ahead"
    end
    none = game_player.run(PlaceGames.wall_down_the_side(:none), frames: 2).screen

    assert_equal blue, none.pixel(92, 80), "stretched straight, x 92 is past halfway"
  end

  def test_a_face_is_lit_from_its_corners_through_the_shading
    %i[none every_8_pixels].each do |perspective|
      screen = game_player.run(PlaceGames.lit_square(left: 0.0, right: 1.0, perspective: perspective), frames: 2).screen

      assert_equal shown(0x0000), screen.pixel(62, 80), "#{perspective}: dark at the left"
      assert_equal shown(0x7FFF), screen.pixel(175, 80), "#{perspective}: bright at the right"
    end
  end

  def test_a_see_through_picture_leaves_what_is_behind_it
    screen = game_player.run(PlaceGames.lit_square(left: 1.0, right: 1.0, see_through: true), frames: 2).screen

    assert_equal BLACK, screen.pixel(60, 20), "the picture's first pixel is see-through"
    refute_empty (60..179).map { |x| screen.pixel(x, 20) }.reject { |color| color == BLACK }, "the rest of its top row is drawn"
  end

  def test_listed_faces_are_drawn_in_the_order_the_list_gives
    small_last = game_player.run(PlaceGames.listed_faces([0, 1]), frames: 2).screen
    small_first = game_player.run(PlaceGames.listed_faces([1, 0]), frames: 2).screen

    assert_includes [shown(:red), shown(:white)], small_last.pixel(120, 80), "the small square, drawn last, is on top"
    assert_equal tile(3, 3), small_first.pixel(112, 72), "the big square, drawn last, covers the small one"
  end

  # Right and bottom are just past the last pixel drawn, as `inside` counts them.
  def test_faces_are_held_to_a_window_the_game_works_out
    screen = game_player.run(PlaceGames.listed_faces([0], window: [100, 40, 140, 120]), frames: 2).screen

    refute_equal BLACK, screen.pixel(100, 40)
    refute_equal BLACK, screen.pixel(139, 119)
    [[99, 79], [140, 79], [120, 39], [120, 120]].each do |x, y|
      assert_equal BLACK, screen.pixel(x, y), "(#{x}, #{y}) is outside the window"
    end
  end

  def test_a_window_reaching_past_the_screen_is_held_to_it
    screen = game_player.run(PlaceGames.listed_faces([0], window: [-50, -50, 400, 400]), frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(60, 20)
    assert_equal tile(7, 7), screen.pixel(170, 130)
  end

  def test_a_drawing_after_the_viewer_moves_draws_from_where_it_is_now
    screen = game_player.run(PlaceGames.seen_from_two_spots, frames: 2).screen

    refute_equal BLACK, screen.pixel(65, 80), "the first drawing, from the middle"
    assert_equal BLACK, screen.pixel(215, 80), "past the second drawing's face"
    refute_equal BLACK, screen.pixel(200, 80), "the second drawing, half a whole to the left"
  end

  def test_each_face_keeps_its_own_picture_when_the_game_starts_over
    screen = game_player.run(PlaceGames.two_faces(starting_over: true), frames: 3).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105)
  end
end
