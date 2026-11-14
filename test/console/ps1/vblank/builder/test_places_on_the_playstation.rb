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

  # One shape drawn at two positions and facings that change every pass (PlaceGames.moved_shapes):
  # each robot's top left corner is drawn where screen_spot, given the same at: and facing:, says it
  # lands, and the second is not drawn over the first.
  def test_one_shape_drawn_at_two_positions_and_facings_lands_where_its_corners_do
    (2..8).each do |frames|
      played = game_player.run(PlaceGames.moved_shapes, frames: frames)
      after = "after #{played[:frame]} passes"

      assert_equal 56, played[:y0], "the first robot is not turned: its top is a whole above the middle, #{after}"
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

  # The answer key: a lit place declared from data, as a level file gives it, is the same picture as
  # the place declared by point and face calls with the same numbers.
  def test_a_place_declared_by_data_is_drawn_as_the_same_place_declared_by_calls
    by_data = pixels_of(PlaceGames.declared_by_data(data: true))
    by_calls = pixels_of(PlaceGames.declared_by_data(data: false))

    assert_operator by_calls.count { |color| color != BLACK }, :>, 5000, "the place declared by calls is drawn"
    assert_equal by_calls, by_data
  end

  # The answer key: shapes drawn at spots just inside and just past each edge of the view, and at the
  # near limit, are the same picture as the shapes declared where they stand (PlaceGames.shapes_at_edges):
  # the test that passes over a shape out of view passes over none that shows.
  def test_shapes_at_the_edges_of_the_view_are_drawn_as_the_same_shapes_declared_there
    moved = pixels_of(PlaceGames.shapes_at_edges(moved: true))
    declared = pixels_of(PlaceGames.shapes_at_edges(moved: false))

    assert_operator declared.count { |color| color != BLACK }, :>, 20, "the slivers of the declared shapes in view are drawn"
    assert_empty declared.each_index.reject { |k| declared[k] == moved[k] }.map { |k| [k % 240, k / 240] }, "pixels that differ"
  end

  private def pixels_of(program)
    screen = game_player.run(program, frames: 2).screen
    (0...160).flat_map { |y| (0...240).map { |x| screen.pixel(x, y) } }
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

  # The face reaches from x -60 to 300, eight texels across, and is drawn up to the view's last column
  # and no further. Which texel shows in that column is each run's answer key's: the chip reads a
  # pixel half a texel on and the interpreter its middle, so the PlayStation's own run shows texel 7
  # there (test/lowering/ps1/vblank/ir/backends/ps1/test_ps1_polygon_fill.rb) and the runs that play the
  # interpreter's picture texel 6, each held to its key on every pixel by its checked player.
  def test_a_face_wider_than_the_view_is_cut_at_its_edges
    screen = game_player.run(PlaceGames.square(x_scale: 3.0), frames: 2).screen

    assert_equal tile(1, 3), screen.pixel(0, 72)
    refute_equal BLACK, screen.pixel(239, 72), "the view's last column"
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

  # Built for the PlayStation, a face's corners are worked in a loop (Console::Description#code_cache_bytes),
  # on its own screen of 320 by 240: the wall lands from x 80 (two ahead) to 144 (ten ahead), its near half
  # red and its far half blue, the far half narrower in perspective than straight across. Its points
  # turned first, the wall is the same picture as drawn alone.
  def test_a_wall_built_for_the_playstation_lands_where_its_corners_say
    straight = row_of(PlaceGames.wall_down_the_side(:none, console: :ps1))
    leaning = row_of(PlaceGames.wall_down_the_side(:every_8_pixels, console: :ps1))
    turned_first = row_of(PlaceGames.wall_down_the_side(:every_8_pixels, console: :ps1, asked_first: true,
                                                                          drawn_straight_first: true))

    outside_and_in = [76, 84, 140, 148]
    [straight, leaning].each do |row|
      assert_equal [0, shown(0x001F), shown(0x7C00), 0], outside_and_in.map { |x| row.fetch(x) }
    end
    assert_operator straight.index(shown(0x7C00)), :<, leaning.index(shown(0x7C00))
    assert_equal leaning, turned_first
  end

  # The pixels of the row through the middle of the PlayStation's screen, once +program+ has drawn two passes.
  private def row_of(program)
    screen = game_player.run(program, frames: 2).screen
    (0...320).map { |x| screen.pixel(x, 120) }
  end

  # Lit from its dark left corners to its bright right ones, the white face goes from dark to white,
  # brighter towards the right (on the PlayStation's own run, as the chip shades it: test_ps1_face_pieces.rb).
  def test_a_face_is_lit_from_its_corners
    %i[none every_8_pixels].each do |perspective|
      screen = game_player.run(PlaceGames.lit_square(left: 0.0, right: 1.0, perspective: perspective), frames: 2).screen
      reds = (60..179).map { |x| screen.pixel(x, 80) & 0x1F }

      assert_operator reds.first, :<=, 8, "#{perspective}: dark at the left"
      assert_operator reds.last, :>=, 30, "#{perspective}: bright at the right"
      assert_equal reds.sort, reds, "#{perspective}: brighter towards the right"
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

  # The door's slot pointed at the next of three pictures every three passes, by a number worked out as
  # the game runs, and a number that is not one of the place's pictures passed over; the wall beside
  # it keeps its own picture throughout. Every picture the place lists is in video memory from the
  # start, so a change costs the chip nothing.
  def test_a_slot_pointed_at_another_picture_shows_it_from_that_pass
    (2..14).each do |frames|
      played = game_player.run(PlaceGames.changing_door, frames: frames)
      pass = played[:drawn]

      assert_equal shown(PlaceGames.door_color(pass)), played.screen.pixel(60, 80), "the door on pass #{pass}"
      assert_equal tile(1, 1), played.screen.pixel(159, 59), "the wall on pass #{pass}"
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

  # Faces through windows hugging them, passed over in the shared drawing when wholly outside
  # (IR::PlaceDrawing::OUTCODE_EDGES).
  include PlaceGames::WindowHuggingTests
end
