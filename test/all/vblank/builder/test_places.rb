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
        points = Array.new(5) { |k| point(k.to_f, 0.0, 2.0) }
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

  def test_a_shape_moved_to_a_spot_that_is_not_three_numbers_is_refused
    shape = square
    message = refusal do
      place(:robot, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :robot, seen_by: eye, at: [1.0, 2.0] }
    end

    assert_match(/at: needs three numbers/, message)
  end

  def test_a_shape_moved_further_than_a_place_reaches_is_refused
    shape = square
    message = refusal do
      place(:robot, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { screen_spot :robot, 0, seen_by: eye, at: [9000.0, 0.0, 0.0] }
    end

    assert_match(/-8191 to 8191/, message)
  end

  def test_a_shape_facing_that_is_not_three_arrows_is_refused
    shape = square
    message = refusal do
      place(:robot, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :robot, seen_by: eye, facing: { right: [1, 0, 0], up: [0, 1, 0] } }
    end

    assert_match(/facing: needs three arrows/, message)
  end

  def test_a_shape_facing_written_with_arrows_that_are_not_square_is_refused
    shape = square
    message = refusal do
      place(:robot, &shape)
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :robot, seen_by: eye, facing: { right: [1, 0, 0], up: [1, 0, 0], ahead: [0, 0, 1] } }
    end

    assert_match(/square to the other two/, message)
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

  def test_changing_the_picture_of_a_slot_the_place_does_not_have_is_refused
    shape = square
    message = refusal do
      image(:door, "#" => :red) { "##\n##\n" }
      place(:room, &shape)
      change_picture :room, slot: :door, to: :wall
    end

    assert_match(/no slot :door/, message)
  end

  def test_changing_a_slot_to_a_picture_the_place_does_not_list_is_refused
    shape = square
    message = refusal do
      image(:door, "#" => :red) { "##\n##\n" }
      place(:room, &shape)
      change_picture :room, slot: :wall, to: :door
    end

    assert_match(/does not list the picture :door/, message)
  end

  def test_changing_a_slot_to_a_picture_number_the_place_does_not_have_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      change_picture :room, slot: :wall, to: 1
    end

    assert_match(/no picture 1/, message)
  end

  def test_changing_a_slot_to_a_fraction_is_refused
    shape = square
    message = refusal do
      place(:room, &shape)
      frame = var :frame, 0.5
      game_loop { change_picture :room, slot: :wall, to: frame }
    end

    assert_match(/whole number/, message)
  end

  def test_a_place_listing_a_picture_that_is_not_declared_is_refused
    message = refusal do
      place :room do
        pictures :door
        a = point(-1.0, 1.0, 2.0)
        b = point(1.0, 1.0, 2.0)
        c = point(1.0, -1.0, 2.0)
        face a, b, c, picture: :wall, on_picture: [[0, 0], [2, 0], [2, 2]]
      end
    end

    assert_match(/no such image/, message)
  end

  # A place declared from data (`place :room, points: [...], faces: [...]`), as a game reads it
  # from a level file. Each refusal names the face or point by its number in the list.
  SQUARE_POINTS = [[-1.0, 1.0, 2.0], [1.0, 1.0, 2.0], [1.0, -1.0, 2.0], [-1.0, -1.0, 2.0]].freeze

  private def square_face(**changes)
    { points: [0, 1, 2, 3], picture: :wall, on_picture: [[0, 0], [2, 0], [2, 2], [0, 2]] }.merge(changes)
  end

  private def data_refusal(points: SQUARE_POINTS, faces: [square_face], **settings)
    refusal { place :room, points: points, faces: faces, **settings }
  end

  def test_a_face_naming_a_point_past_the_points_is_refused
    message = data_refusal(faces: [square_face, square_face(points: [0, 1, 4])])

    assert_match(/face 1 \(in faces:\)/, message)
    assert_match(/no point 4/, message)
    assert_match(/0 to 3/, message)
  end

  def test_a_face_of_too_few_or_too_many_points_is_refused
    corner = [0, 0]
    [[0, 1], [0, 1, 2, 3, 0]].each do |points|
      message = data_refusal(faces: [square_face(points: points, on_picture: [corner] * points.length)])

      assert_match(/face 0 \(in faces:\) with #{points.length} points/, message)
      assert_match(/3 or 4 points/, message)
    end
  end

  def test_a_face_whose_picture_the_place_does_not_list_is_refused
    by_number = data_refusal(faces: [square_face(picture: 2)], pictures: %i[wall])
    by_name = data_refusal(faces: [square_face(picture: :lava)])

    assert_match(/face 0 \(in faces:\) with the picture 2/, by_number)
    assert_match(/lists 1 picture/, by_number)
    assert_match(/no such image/, by_name)
  end

  def test_a_face_in_a_block_whose_picture_number_the_place_does_not_list_is_refused
    message = refusal do
      place :room do
        pictures :wall
        face point(0.0, 0.0, 2.0), point(1.0, 0.0, 2.0), point(1.0, 1.0, 2.0), picture: 1,
                                                                                on_picture: [[0, 0], [2, 0], [2, 2]]
      end
    end

    assert_match(/a face with the picture 1/, message)
    assert_match(/lists 1 picture/, message)
  end

  def test_a_point_that_is_not_three_numbers_is_refused
    message = data_refusal(points: [*SQUARE_POINTS.first(3), [1.0, 2.0]])

    assert_match(/point 3 \(in points:\)/, message)
    assert_match(/three numbers/, message)
  end

  def test_a_face_that_is_not_a_hash_of_known_keys_is_refused
    not_a_hash = data_refusal(faces: [[0, 1, 2, 3]])
    unknown_key = data_refusal(faces: [square_face(colour: :red)])
    string_keys = data_refusal(faces: [square_face.transform_keys(&:to_s)])
    no_picture = data_refusal(faces: [square_face.except(:picture)])

    assert_match(/face 0 \(in faces:\)/, not_a_hash)
    assert_match(/points:, picture:, on_picture:/, not_a_hash)
    assert_match(/colour/, unknown_key)
    assert_match(/symbolize_names: true/, string_keys)
    assert_match(/with no picture:/, no_picture)
  end

  def test_a_place_given_both_data_and_a_block_or_only_half_its_data_is_refused
    shape = square
    faces = [square_face]
    both = refusal { place(:room, points: SQUARE_POINTS, faces: faces, &shape) }
    no_faces = refusal { place :room, points: SQUARE_POINTS }
    no_block = refusal { place :room }

    assert_match(/both/, both)
    assert_match(/faces:/, no_faces)
    assert_match(/points: and faces:/, no_block)
  end

  def test_a_facing_that_is_not_three_square_arrows_is_refused
    message = refusal { viewer :eye, at: [0.0, 0.0, 0.0], facing: { right: [1, 0, 0], up: [1, 0, 0], ahead: [0, 0, 1] } }

    assert_match(/square to/, message)
  end
end
