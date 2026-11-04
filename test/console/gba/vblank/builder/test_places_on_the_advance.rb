# frozen_string_literal: true

require "test_helper"

# Small games of places made of flat faces, kept once for this file and for the test of the
# Advance's cartridge (test/lowering/gba/vblank/builder/test_places_cartridge.rb).
module PlaceGames
  # A picture of 8 by 8 pixels, every pixel its own colour: red counts across and green counts
  # down, so a pixel on the screen says which pixel of the picture landed there.
  TILE = (0...8).flat_map { |down| (0...8).map { |across| (across * 4) | ((down * 4) << 5) | (31 << 10) } }.freeze

  # The colour of the picture's pixel +across+, +down+.
  def self.tile(across, down) = TILE[(down * 8) + across]

  # A square face two wholes wide, two wholes in front of a viewer that faces straight ahead. The
  # view is 90 degrees across a screen 240 pixels wide, so a point one whole to the side at two
  # wholes ahead lands 60 pixels from the middle: the face covers x 60 to 179 and y 20 to 139.
  # +on_picture+ is where its corners fall on the picture, top left first, round to the right.
  # +x_scale+ makes the face wider.
  # +turned_round+ gives the corners the other way round, so the face is seen from behind.
  def self.square(on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]], x_scale: 1.0, turned_round: false, both_sides: false)
    one_place(both_sides: both_sides) do
      corners = [point(-x_scale, 1.0, 2.0), point(x_scale, 1.0, 2.0), point(x_scale, -1.0, 2.0),
                 point(-x_scale, -1.0, 2.0)]
      corners = corners.reverse if turned_round
      face(*corners, picture: :tile, on_picture: turned_round ? on_picture.reverse : on_picture)
    end
  end

  # A floor one whole below the viewer, from a whole behind them to three ahead: the near limit
  # cuts it, and what is left runs from row 120 (three wholes ahead lands 40 rows below the
  # middle) down past the bottom of the screen.
  def self.floor
    one_place do
      face point(-1.0, -1.0, 3.0), point(1.0, -1.0, 3.0), point(1.0, -1.0, -1.0), point(-1.0, -1.0, -1.0),
           picture: :tile, on_picture: [[0, 0], [8, 0], [8, 32], [0, 32]]
    end
  end

  # A face as far behind a turned viewer as a place reaches: the viewer stands at one far corner
  # of the place facing out of it, and the face is near the other.
  def self.far_behind
    slant = Math.sqrt(0.5)
    one_place(both_sides: true,
              at: [-8191.0, 0.0, -8191.0],
              facing: { right: [-slant, 0, slant], up: [0, 1, 0], ahead: [-slant, 0, -slant] }) do
      face point(6293.0, 1000.0, 7707.0), point(7707.0, 1000.0, 6293.0), point(7707.0, -1000.0, 6293.0),
           point(6293.0, -1000.0, 7707.0), picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
    end
  end

  # A game of one place, declared by the block, drawn every pass by a viewer at +at+.
  def self.one_place(both_sides: false, at: [0.0, 0.0, 0.0], facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] },
                     &shape)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      place(:wall, &shape)
      eye = viewer :eye, at: at, facing: facing
      game_loop do
        clear_screen :black
        draw_place :wall, seen_by: eye, both_sides: both_sides
      end
    end
    builder.finalize_program
    builder.program
  end

  # A face of five corners filled straight from a list, with what it shows changing every pass:
  # the edges nothing outside is drawn move, the picture it shows is the other of two, and it is
  # drawn without perspective, then in perspective every eight pixels, then every pixel. These
  # are the numbers a game works out as it runs, so a target that settled them while building
  # draws the wrong face on every pass but the first.
  #
  # The fill is written straight into the game (Builder#record), as a place's routine writes one:
  # no verb hands a game a fill of its own.
  #
  # +passes+ is how many passes each change lasts. A run checked against the interpreter on every
  # pass wants 1. The cartridge's picture is compared at a frame, and the cartridge reaches its
  # first pass a pass later than this small a program usually does, so it wants a change slow
  # enough that the frame compared is in the middle of one.
  def self.moving_five_corners(passes: 1)
    numbers = [[100, 20, -3, -2, 1 << 26], [140, 30, 12, -2, 1 << 24], [135, 70, 12, 9, 3 << 23],
               [95, 80, -3, 13, 1 << 25], [80, 50, -5, 5, 1 << 27]]
              .flat_map { |x, y, u, v, w| [x * 16, y * 16, u << 16, v << 16, w] }
    builder = VBlank::Builder.new
    builder.instance_eval do
      b = VBlank::IR::Build
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      image(:stripes, "r" => :red, "w" => :white) { "rw\nrw\n" }
      corners = list :corners, capacity: 40, full_of: 0
      numbers.each_with_index { |number, at| corners[at] = number }
      frame = var :frame, 0
      game_loop do
        clear_screen :black
        at = b.binop(:/, b.var_ref(frame.name), passes)
        # Without perspective, then every eight pixels, then every pixel, by turns.
        turn = b.binop(:%, at, 3)
        perspective = b.binop(:+, b.binop(:*, b.binop(:==, turn, 1), 8), b.binop(:==, turn, 2))
        record(b.fill_face(%i[tile stripes], b.binop(:%, at, 2), :corners, 5,
                           [b.binop(:+, 70, b.binop(:%, b.binop(:*, at, 7), 40)), b.binop(:%, b.binop(:*, at, 3), 40),
                            b.binop(:-, 140, b.binop(:%, b.binop(:*, at, 11), 30)), 160],
                           perspective: perspective))
        frame += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # A wall down the left of a viewer facing ahead, a whole to the left, from two wholes ahead to
  # ten, a picture red for its near half and blue for its far half laid along it. It lands from x
  # 60 (two ahead) to 108 (ten ahead), and the picture's halfway, six ahead, at x 100. Without
  # perspective the picture is stretched straight across, so its halfway lands halfway, at 84.
  # Drawn with +perspective+.
  def self.wall_down_the_side(perspective)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :halves, width: 64, height: 8, data: (0...8).flat_map { (0...64).map { |across| across < 32 ? 0x001F : 0x7C00 } }
      place :side do
        face point(-1.0, 1.0, 2.0), point(-1.0, 1.0, 10.0), point(-1.0, -1.0, 10.0), point(-1.0, -1.0, 2.0),
             picture: :halves, on_picture: [[0, 0], [64, 0], [64, 8], [0, 8]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :side, seen_by: eye, perspective: perspective
      end
    end
    builder.finalize_program
    builder.program
  end

  # Two squares two wholes ahead, the big one (face 0, the tile) covering x 60 to 179 and y 20 to
  # 139 and the small one (face 1, stripes) in its middle, x 90 to 149 and y 50 to 109. The game
  # draws the face numbers in +order+, from a list it fills, so a later face is drawn over an
  # earlier one. +window+, if given, is the rectangle they are held to, worked out as the game
  # runs: the numbers are put in variables on every pass.
  def self.listed_faces(order, window: nil)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      image(:stripes, "r" => :red, "w" => :white) { "rw\nrw\n" }
      place :pair do
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
        face point(-0.5, 0.5, 2.0), point(0.5, 0.5, 2.0), point(0.5, -0.5, 2.0), point(-0.5, -0.5, 2.0),
             picture: :stripes, on_picture: [[0, 0], [2, 0], [2, 2], [0, 2]]
      end
      drawn = list :drawn, capacity: 4
      order.each { |number| drawn.push number }
      edges = %i[left top right bottom].map { |edge| var(edge, 0) }
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        if window
          edges.zip(window).each { |edge, number| edge.store!(number) }
          draw_place :pair, seen_by: eye, faces: drawn, window: edges
        else
          draw_place :pair, seen_by: eye, faces: drawn
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # The points +spots+ ([x, y, z] each) of a place, each asked where it lands on the screen of a
  # viewer at the middle facing ahead, the answers kept in variables x0, y0 and behind0 onwards.
  def self.screen_spots(spots)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      numbers = []
      place :marks do
        numbers.concat(spots.map { |x, y, z| point(x, y, z) })
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      answers = numbers.each_with_index.map { |_, k| [var(:"x#{k}", -1), var(:"y#{k}", -1), var(:"behind#{k}", -1)] }
      game_loop do
        numbers.zip(answers).each do |number, (x, y, behind)|
          spot = screen_spot(:marks, number, seen_by: eye)
          x.store!(spot.x)
          y.store!(spot.y)
          behind.store!(0)
          behind.store!(1) if spot.behind?
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # Two faces, a square and a triangle, side by side, each with a picture of its own.
  # +starting_over+ declares them in a part the game puts back as declared on every pass, so
  # what each face shows is what the place declared, however it got there.
  def self.two_faces(starting_over: false)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      part :play if starting_over
      image :tile, width: 8, height: 8, data: TILE
      image(:stripes, "r" => :red, "w" => :white) { "rw\nrw\n" }
      place :pair do
        a = point(-3.0, 1.0, 4.0)
        b = point(-1.0, 1.0, 4.0)
        c = point(-1.0, -1.0, 4.0)
        d = point(-3.0, -1.0, 4.0)
        e = point(1.0, 1.0, 4.0)
        f = point(3.0, -1.0, 4.0)
        g = point(1.0, -1.0, 4.0)
        face a, b, c, d, picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
        face e, f, g, picture: :stripes, on_picture: [[0, 0], [16, 16], [0, 16]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :pair, seen_by: eye, both_sides: false
        start_over :play if starting_over
      end
    end
    builder.finalize_program
    builder.program
  end
end

# A place made of flat faces, drawn as a viewer sees it: the picture of each face where the sums
# say it lands, repeating past its edges, and nothing outside the face. Every lowering that plays
# games as the Advance draws the same picture (the Color, the Super Nintendo and the Genesis
# refuse a place; see test/all/vblank/ir/guardrails/test_console_answers.rb).
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
  def test_each_face_keeps_its_own_picture_when_the_game_starts_over
    screen = game_player.run(PlaceGames.two_faces(starting_over: true), frames: 3).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105)
  end
end
