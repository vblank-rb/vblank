# frozen_string_literal: true

require "test_helper"
require "place_games"

# The model of the PlayStation graphics chip's triangle fill (PS1::PolygonFill), which the
# PlayStation's checked run draws a place's faces with on the interpreter's side, held to the chip in
# Beetle PSX: the same face, every pixel. A model one rule wrong is caught, so the check is not one that
# passes whatever the model says.
class TestPS1PolygonFill < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  Fill = PS1::PolygonFill

  def test_the_model_draws_a_stretched_face_as_the_chip_does
    assert PS1::CheckedRun.new.run(PlaceGames.square, frames: 2)
  end

  def test_a_face_in_perspective_cut_into_squares_is_drawn_as_the_chip_draws_it
    assert PS1::CheckedRun.new.run(PlaceGames.wall_down_the_side(:every_pixel), frames: 2)
  end

  # A picture repeated 250 times across a face runs past a byte inside each square the face is cut into,
  # so each square is cut again on the picture (FacePieces.send_cut_on_picture) before it is sent.
  def test_a_face_whose_picture_runs_past_a_byte_is_cut_on_the_picture_as_the_chip_needs
    many = PlaceGames.square(on_picture: [[0, 0], [2000, 0], [2000, 2000], [0, 2000]])

    assert PS1::CheckedRun.new.run(many, frames: 2)
  end

  # The chip's corners are whole pixels, each rounded to the nearest, so a face whose lowest corners
  # land halfway into row 79 reaches down to the row's end and the chip fills row 79. The test that
  # passes over a face lying wholly outside its window (IR::PlaceDrawing::OUTCODE_EDGES) must not
  # pass over this one through a window whose top is row 79, though the interpreter's fill, which takes
  # a row only when the face covers its middle, draws nothing there.
  def test_a_face_reaching_halfway_into_its_windows_first_row_fills_that_row
    screen = PS1::CheckedRun.new.run(PlaceGames.strip_reaching_into_window_row, frames: 2).screen

    refute_equal VBlank::Testing.shown(:black), screen.pixel(120, 79)
    assert_equal VBlank::Testing.shown(:black), screen.pixel(120, 80)
  end

  # The chip starts the place on the picture half a texel on (gpu_uv_seed). Without that, about half
  # the pixels of a picture stretched 15 times read the texel before.
  def test_a_model_without_the_half_texel_start_disagrees_with_the_chip
    wrong = Fill.new(texel_seed: 0)

    error = assert_raises(VBlank::IR::Backends::RunComparison::Disagreement) do
      PS1::CheckedRun.new.use_polygon_fill(wrong).run(PlaceGames.square, frames: 2)
    end
    assert_match(/picture differs/, error.message)
  end

  # Three corners at (0, 0), (4, 0) and (0, 4): the chip fills the pixels whose top-left corners are
  # inside, the right and bottom edges left out, so rows of 4, 3, 2 and 1 pixels.
  def test_a_triangle_leaves_out_its_right_and_bottom_edges
    drawn = []
    Fill.new.fill([[0, 0, 0, 0], [4, 0, 0, 0], [0, 4, 0, 0]], [0, 0, 319, 239]) { |x, y, _u, _v| drawn << [x, y] }

    assert_equal [4, 3, 2, 1], (0..3).map { |row| drawn.count { |_x, y| y == row } }
  end

  def test_the_drawing_area_holds_every_pixel_its_right_and_bottom_included
    drawn = []
    Fill.new.fill([[0, 0, 0, 0], [40, 0, 0, 0], [0, 40, 0, 0]], [5, 6, 9, 8]) { |x, y, _u, _v| drawn << [x, y] }

    assert_equal [5, 9, 6, 8], [*drawn.map(&:first).minmax, *drawn.map(&:last).minmax]
  end
end
