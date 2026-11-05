# frozen_string_literal: true

require "test_helper"
require "place_games"

# A place made of flat faces, drawn as a viewer sees it: the picture of each face where the sums
# say it lands, repeating past its edges, and nothing outside the face. Every lowering that plays
# games as the Advance draws the same picture (the Color, the Super Nintendo and the Genesis
# refuse a place; see test/all/vblank/ir/guardrails/test_console_answers.rb). The PlayStation's
# screen is another size, so its twin is test/console/ps1/vblank/builder/test_places_on_the_playstation.rb.
class TestPlacesOnTheAdvance < Minitest::Test
  BLACK = VBlank::Testing.shown(:black)

  private def tile(across, down) = shown(PlaceGames.tile(across, down))

  def test_a_square_face_lands_where_the_view_says_with_its_picture_stretched_across
    screen = game_player.run(PlaceGames.square, frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(60, 20)
    assert_equal tile(7, 0), screen.pixel(179, 20)
    assert_equal tile(0, 7), screen.pixel(60, 139)
    assert_equal tile(7, 7), screen.pixel(179, 139)
    assert_equal tile(3, 3), screen.pixel(119, 79)
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

  # One shape drawn at two positions and facings that change every pass (PlaceGames.moved_shapes):
  # each robot's top left corner is drawn where screen_spot, given the same at: and facing:, says it
  # lands, and the second is not drawn over the first.
  def test_one_shape_drawn_at_two_positions_and_facings_lands_where_its_corners_do
    (2..8).each do |frames|
      played = game_player.run(PlaceGames.moved_shapes, frames: frames)
      after = "after #{played[:frame]} passes"

      assert_equal 56, played[:y0], "the first robot is not turned: its top is a whole above the middle, #{after}"
      assert_includes 48..66, played[:x0], "the first robot's corner, a whole left of its middle, #{after}"
      assert_includes 126..150, played[:x1], "the second robot's corner, #{after}"
      2.times do |k|
        x = played[:"x#{k}"]
        y = played[:"y#{k}"]

        assert_equal tile(0, 0), played.screen.pixel(x + 2, y + 2), "inside robot #{k}'s corner, #{after}"
        assert_equal BLACK, played.screen.pixel(x - 2, y + 2), "left of robot #{k}'s corner, #{after}"
      end
      assert_equal BLACK, played.screen.pixel(123, 80), "between the robots, #{after}"
    end
  end

  # The answer key: a shape moved and turned, seen by a turned viewer, lit, through a window and in
  # perspective, is the same picture as the shape declared where that puts it.
  def test_a_moved_shape_is_drawn_as_the_same_shape_declared_where_it_stands
    moved = pixels_of(PlaceGames.stance_against_declared(moved: true))
    declared = pixels_of(PlaceGames.stance_against_declared(moved: false))

    assert_operator declared.count { |color| color != BLACK }, :>, 1000, "the declared square is drawn"
    assert_equal declared, moved
  end

  private def pixels_of(program)
    screen = game_player.run(program, frames: 2).screen
    (0...160).flat_map { |y| (0...240).map { |x| screen.pixel(x, y) } }
  end

  def test_nothing_is_drawn_outside_the_face
    screen = game_player.run(PlaceGames.square, frames: 2).screen

    [[59, 20], [180, 20], [60, 19], [60, 140], [179, 140], [180, 139]].each do |x, y|
      assert_equal BLACK, screen.pixel(x, y), "(#{x}, #{y}) is outside the face"
    end
  end

  # A corner can fall anywhere on the picture, below nought and far past its edge, and the picture
  # repeats like wallpaper. Across the 120 pixels of the face the picture runs from -70 to 140,
  # 1.75 of its pixels for each pixel of the screen, and the same down.
  def test_a_picture_repeats_past_its_edges_both_ways
    screen = game_player.run(PlaceGames.square(on_picture: [[-70, -70], [140, -70], [140, 140], [-70, 140]]),
                             frames: 2).screen

    assert_equal tile(2, 2), screen.pixel(60, 20), "-70 is 2 past a repeat at -72"
    assert_equal tile(3, 2), screen.pixel(61, 20), "-68.25 is in the pixel from -69"
    assert_equal tile(1, 2), screen.pixel(64, 20), "-63 is 1 past a repeat at -64"
    assert_equal tile(2, 4), screen.pixel(60, 21), "a row down is 1.75 further down the picture"
    assert_equal tile(2, 2), screen.pixel(179, 20), "138.25 is 2 past a repeat at 136"
    # Past the bottom of the picture: the last row's v starts at -70 + 0.875 (half a row in, of
    # 1.75 a row) and steps 119 rows of 114686/65536 each, to 9117457/65536, about 139.1 — row 3
    # of the repeat starting at 136.
    assert_equal tile(2, 3), screen.pixel(60, 139), "139.1 down is 3 past a repeat at 136"
  end

  def test_a_face_wider_than_the_screen_is_cut_at_its_edges
    screen = game_player.run(PlaceGames.square(x_scale: 3.0), frames: 2).screen

    assert_equal tile(1, 3), screen.pixel(0, 79)
    assert_equal tile(6, 3), screen.pixel(239, 79)
    assert_equal BLACK, screen.pixel(0, 19)
    assert_equal BLACK, screen.pixel(239, 140)
  end

  # The floor's far edge lands on row 120, 40 pixels either side of the middle, and the near limit
  # cuts its near edge where it lands far below the screen, so it widens down to the bottom row.
  def test_a_face_half_behind_the_viewer_is_cut_at_the_near_limit
    screen = game_player.run(PlaceGames.floor, frames: 2).screen

    refute_equal BLACK, screen.pixel(120, 150), "in front of the viewer, below the far edge"
    refute_equal BLACK, screen.pixel(60, 159), "the floor widens towards the viewer"
    assert_equal BLACK, screen.pixel(120, 119), "above the far edge"
    assert_equal BLACK, screen.pixel(30, 159), "outside the floor's side"
  end

  def test_a_face_seen_from_behind_is_left_out_unless_both_sides_are_drawn
    behind = game_player.run(PlaceGames.square(turned_round: true), frames: 2).screen
    both = game_player.run(PlaceGames.square(turned_round: true, both_sides: true), frames: 2).screen

    assert_equal BLACK, behind.pixel(119, 79)
    assert_equal tile(0, 0), both.pixel(60, 20)
  end

  def test_a_face_as_far_behind_the_viewer_as_a_place_reaches_is_not_drawn
    screen = game_player.run(PlaceGames.far_behind, frames: 2).screen

    drawn = (0...160).step(4).flat_map { |y| (0...240).step(4).map { |x| screen.pixel(x, y) } }.reject { |color| color == BLACK }
    assert_empty drawn
  end

  # The face's edges and its picture are numbers worked out as the game runs: on every pass both
  # are new, and every pass is checked.
  def test_a_face_whose_edges_and_picture_change_every_pass
    screen = game_player.run(PlaceGames.moving_five_corners, frames: 8).screen

    refute_equal BLACK, screen.pixel(110, 60)
  end

  # The same, lit from its corners: every pass checked with the light blended across it.
  def test_a_lit_face_whose_edges_and_picture_change_every_pass
    screen = game_player.run(PlaceGames.moving_five_corners(lit: true), frames: 8).screen

    refute_equal BLACK, screen.pixel(110, 60)
  end

  def test_each_face_shows_its_own_picture_and_a_face_can_have_three_corners
    screen = game_player.run(PlaceGames.two_faces, frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105), "the triangle's left edge is red"
    assert_equal BLACK, screen.pixel(209, 51), "above the triangle's slope"
  end

  # The picture's halfway down a wall that leans away is where the wall is six wholes ahead, x 100,
  # in perspective; stretched straight, it is halfway across the wall's span on the screen, x 84.
  def test_a_picture_on_a_wall_leaning_away_is_in_perspective_by_default
    red = shown(0x001F)
    blue = shown(0x7C00)
    every_8 = game_player.run(PlaceGames.wall_down_the_side(:every_8_pixels), frames: 2).screen
    every_pixel = game_player.run(PlaceGames.wall_down_the_side(:every_pixel), frames: 2).screen
    none = game_player.run(PlaceGames.wall_down_the_side(:none), frames: 2).screen

    [every_8, every_pixel].each do |screen|
      assert_equal red, screen.pixel(92, 80), "x 92 is under six wholes ahead"
      assert_equal blue, screen.pixel(104, 80), "x 104 is past six wholes ahead"
    end
    assert_equal blue, none.pixel(92, 80), "stretched straight, x 92 is past halfway"
    assert_equal red, none.pixel(80, 80)
  end

  # Lit from dark at its left corners to bright at its right, the face's white goes through the
  # shading's four levels across it: a pixel's level is its light times four, whole part.
  def test_a_face_is_lit_from_its_corners_through_the_shading
    %i[none every_8_pixels].each do |perspective|
      screen = game_player.run(PlaceGames.lit_square(left: 0.0, right: 1.0, perspective: perspective), frames: 2).screen

      assert_equal shown(0x0000), screen.pixel(62, 80), "dark at the left"
      assert_equal shown(0x2108), screen.pixel(95, 80), "a third of the way: the second level"
      assert_equal shown(0x4210), screen.pixel(125, 80), "past halfway: the third level"
      assert_equal shown(0x7FFF), screen.pixel(175, 80), "bright at the right"
    end
  end

  # What the game adds to each point's light as it runs lights the face, held to the brightest.
  def test_light_the_game_adds_to_its_points_lights_the_face
    screen = game_player.run(PlaceGames.lit_square(left: 0.0, right: 0.0, added: 0.8), frames: 2).screen
    brightest = game_player.run(PlaceGames.lit_square(left: 0.5, right: 0.5, added: 0.9), frames: 2).screen

    assert_equal shown(0x7FFF), screen.pixel(120, 80), "0.8 of the way up is the brightest of four levels"
    assert_equal shown(0x7FFF), brightest.pixel(120, 80), "more than all the light is all of it"
  end

  # Its points turned first by a question with a nearer limit and by a drawing without perspective, the
  # drawing in perspective reads them and is the same picture as drawn alone.
  def test_a_wall_whose_points_were_turned_first_is_drawn_the_same
    alone = game_player.run(PlaceGames.wall_down_the_side(:every_8_pixels), frames: 2).screen
    after = game_player.run(PlaceGames.wall_down_the_side(:every_8_pixels, asked_first: true, drawn_straight_first: true),
                            frames: 2).screen

    assert_equal shown(0x001F), after.pixel(92, 80)
    assert_equal shown(0x7C00), after.pixel(104, 80)
    assert_equal((56..112).map { |x| alone.pixel(x, 80) }, (56..112).map { |x| after.pixel(x, 80) })
  end

  def test_the_default_perspective_is_every_8_pixels
    default = game_player.run(PlaceGames.wall_down_the_side(Builder::Places::PERSPECTIVE), frames: 2).screen

    assert_equal :every_8_pixels, Builder::Places::PERSPECTIVE
    assert_equal shown(0x001F), default.pixel(92, 80)
  end

  def test_listed_faces_are_drawn_in_the_order_the_list_gives
    small_last = game_player.run(PlaceGames.listed_faces([0, 1]), frames: 2).screen
    small_first = game_player.run(PlaceGames.listed_faces([1, 0]), frames: 2).screen

    assert_includes [shown(:red), shown(:white)], small_last.pixel(120, 80), "the small square, drawn last, is on top"
    assert_equal tile(3, 3), small_first.pixel(119, 79), "the big square, drawn last, covers the small one"
  end

  def test_a_face_left_out_of_the_list_is_not_drawn
    screen = game_player.run(PlaceGames.listed_faces([1]), frames: 2).screen

    assert_equal BLACK, screen.pixel(60, 20), "the big square is not in the list"
    refute_equal BLACK, screen.pixel(120, 80)
  end

  def test_a_number_that_is_not_a_face_is_passed_over
    screen = game_player.run(PlaceGames.listed_faces([7, -1, 0]), frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(60, 20)
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
    assert_equal tile(7, 7), screen.pixel(179, 139)
  end

  # A place whose part the game puts back as declared shows each face's own picture afterwards.
  def test_a_drawing_after_the_viewer_moves_draws_from_where_it_is_now
    screen = game_player.run(PlaceGames.seen_from_two_spots, frames: 2).screen

    refute_equal BLACK, screen.pixel(65, 80), "the first drawing, from the middle"
    assert_equal BLACK, screen.pixel(215, 80), "past the second drawing's face"
    refute_equal BLACK, screen.pixel(200, 80), "the second drawing, half a whole to the left"
  end

  # The door's slot pointed at the next of three pictures every three passes, by a number worked out as
  # the game runs, and a number that is not one of the place's pictures passed over; the wall beside
  # it keeps its own picture throughout.
  def test_a_slot_pointed_at_another_picture_shows_it_from_that_pass
    (2..14).each do |frames|
      played = game_player.run(PlaceGames.changing_door, frames: frames)
      pass = played[:drawn]

      assert_equal shown(PlaceGames.door_color(pass)), played.screen.pixel(60, 80), "the door on pass #{pass}"
      assert_equal tile(0, 0), played.screen.pixel(151, 51), "the wall on pass #{pass}"
    end
  end

  def test_a_slot_pointed_at_a_picture_by_its_name_shows_it
    screen = game_player.run(PlaceGames.changing_door(named: true), frames: 2).screen

    assert_equal shown(:blue), screen.pixel(60, 80)
  end

  def test_each_face_keeps_its_own_picture_when_the_game_starts_over
    screen = game_player.run(PlaceGames.two_faces(starting_over: true), frames: 3).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105)
  end
end
