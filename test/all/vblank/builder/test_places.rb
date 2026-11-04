# frozen_string_literal: true

require "test_helper"

# The friendly errors of `place`, `viewer`, `draw_place` and `screen_spot`, said while the game is built. What a
# place draws is in test/console/gba/vblank/builder/test_places_on_the_advance.rb.
class TestPlaces < Minitest::Test
  private def build(tear_free: true, picture: "##\n##\n", &block)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image(:wall, "#" => :white) { picture }
    end
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def square
    proc do
      a = point(-1.0, 1.0, 2.0)
      b = point(1.0, 1.0, 2.0)
      c = point(1.0, -1.0, 2.0)
      d = point(-1.0, -1.0, 2.0)
      face a, b, c, d, picture: :wall, on_picture: [[0, 0], [2, 0], [2, 2], [0, 2]]
    end
  end

  private def refusal(**opts, &block)
    assert_raises(ArgumentError) { build(**opts, &block) }.message
  end

  def test_a_place_on_a_screen_that_is_not_tear_free_is_refused
    shape = square
    message = refusal(tear_free: false) do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :room, seen_by: eye }
    end

    assert_match(/tear_free: true/, message)
  end

  def test_a_picture_whose_sides_are_not_a_power_of_two_is_refused
    shape = square
    message = refusal(picture: "###\n###\n") { place(:room, &shape) }

    assert_match(/1, 2, 4, 8/, message)
  end

  def test_a_face_of_five_points_is_refused
    message = refusal do
      place :room do
        points = 5.times.map { |k| point(k.to_f, 0.0, 2.0) }
        face(*points, picture: :wall, on_picture: [[0, 0]] * 5)
      end
    end

    assert_match(/3 or 4 points/, message)
  end

  def test_corners_that_do_not_match_the_points_are_refused
    message = refusal do
      place :room do
        a = point(0.0, 0.0, 2.0)
        b = point(1.0, 0.0, 2.0)
        c = point(1.0, 1.0, 2.0)
        face a, b, c, picture: :wall, on_picture: [[0, 0], [2, 0]]
      end
    end

    assert_match(/one \[across, down\] for each point/, message)
  end

  def test_a_perspective_that_is_not_one_of_the_settings_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :room, seen_by: eye, perspective: :sometimes }
    end

    assert_match(/The settings are :none, :every_8_pixels, :every_pixel/, message)
  end

  def test_a_point_further_than_a_place_reaches_is_refused
    message = refusal do
      place :room do
        a = point(9000.0, 0.0, 2.0)
        b = point(1.0, 0.0, 2.0)
        c = point(1.0, 1.0, 2.0)
        face a, b, c, picture: :wall, on_picture: [[0, 0], [2, 0], [2, 2]]
      end
    end

    assert_match(/-8191 to 8191/, message)
  end

  def test_faces_that_are_not_a_list_are_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :room, seen_by: eye, faces: [0] }
    end

    assert_match(/faces: needs a list/, message)
  end

  def test_a_window_that_is_not_four_edges_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :room, seen_by: eye, window: [0, 0, 240] }
    end

    assert_match(/window: needs four/, message)
  end

  def test_a_window_edge_that_is_a_fraction_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      edge = var :edge, 1.5
      game_loop { draw_place :room, seen_by: eye, window: [edge, 0, 240, 160] }
    end

    assert_match(/whole number/, message)
  end

  def test_a_screen_spot_of_a_place_that_was_never_declared_is_refused
    message = refusal do
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      screen_spot :nowhere, 0, seen_by: eye
    end

    assert_match(/no place :nowhere/, message)
  end

  def test_a_screen_spot_of_a_point_the_place_does_not_have_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      screen_spot :room, 4, seen_by: eye
    end

    assert_match(/has no point 4/, message)
  end

  def test_a_place_that_was_never_declared_is_refused
    message = refusal do
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :nowhere, seen_by: eye }
    end

    assert_match(/no place :nowhere/, message)
  end

  def test_a_facing_that_is_not_three_square_arrows_is_refused
    message = refusal { viewer :eye, at: [0.0, 0.0, 0.0], facing: { right: [1, 0, 0], up: [1, 0, 0], ahead: [0, 0, 1] } }

    assert_match(/square to/, message)
  end
end
