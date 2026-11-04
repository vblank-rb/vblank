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
  def self.square(on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]], x_scale: 1.0, z: 2.0, near_corner: nil)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      place :wall do
        a = point(-x_scale, 1.0, near_corner || z)
        b = point(x_scale, 1.0, z)
        c = point(x_scale, -1.0, z)
        d = point(-x_scale, -1.0, z)
        face a, b, c, d, picture: :tile, on_picture: on_picture
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :wall, seen_by: eye
      end
    end
    builder.finalize_program
    builder.program
  end

  # Two faces, a square and a triangle, side by side, each with a picture of its own.
  def self.two_faces
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
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
        draw_place :pair, seen_by: eye
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
  end

  def test_a_face_wider_than_the_screen_is_cut_at_its_edges
    screen = game_player.run(PlaceGames.square(x_scale: 3.0), frames: 2).screen

    assert_equal tile(1, 3), screen.pixel(0, 79)
    assert_equal tile(6, 3), screen.pixel(239, 79)
    assert_equal BLACK, screen.pixel(0, 19)
    assert_equal BLACK, screen.pixel(239, 140)
  end

  def test_a_face_with_a_corner_nearer_than_the_near_limit_is_left_out
    screen = game_player.run(PlaceGames.square(near_corner: 0.1), frames: 2).screen

    assert_equal BLACK, screen.pixel(119, 79)
  end

  def test_each_face_shows_its_own_picture_and_a_face_can_have_three_corners
    screen = game_player.run(PlaceGames.two_faces, frames: 2).screen

    assert_equal tile(0, 0), screen.pixel(30, 50)
    assert_equal shown(:red), screen.pixel(150, 105), "the triangle's left edge is red"
    assert_equal BLACK, screen.pixel(209, 51), "above the triangle's slope"
  end
end
