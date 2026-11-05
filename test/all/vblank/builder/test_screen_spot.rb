# frozen_string_literal: true

require "test_helper"
require "place_games"

# `screen_spot`: where a point of a place lands on the screen as a viewer sees it, worked out as
# the game runs. It is only sums, so every console works it out, on its own screen: the game keeps
# the screen's size in variables, and the answers are checked against that.
class TestScreenSpot < Minitest::Test
  # A game asking where each of +spots+ ([x, y, z] each) lands for a viewer at the middle facing
  # ahead, its answers kept in x0, y0, behind0 onwards.
  private def game(spots)
    builder = VBlank::Builder.new
    builder.instance_eval do
      image :mark, width: 2, height: 2, data: [0x7fff] * 4
      numbers = []
      place :marks do
        numbers.concat(spots.map { |x, y, z| point(x, y, z) })
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0),
             picture: :mark, on_picture: [[0, 0], [2, 0], [2, 2]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      var :width, screen_width
      var :height, screen_height
      answers = numbers.each_index.map { |k| [var(:"x#{k}", -1), var(:"y#{k}", -1), var(:"behind#{k}", -1)] }
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

  private def answer(played, k) = [played[:"x#{k}"], played[:"y#{k}"], played[:"behind#{k}"]]

  # The view is 90 degrees across, so a point one whole to the side at two wholes ahead lands a
  # quarter of the screen's width from the middle, and one whole up lands that far above it.
  def test_a_point_in_front_lands_where_a_face_corner_would
    played = game_player.run(game([[-1.0, 1.0, 2.0], [1.0, -1.0, 2.0]]), frames: 2)
    width = played[:width]
    height = played[:height]

    assert_equal [width / 4, (height / 2) - (width / 4), 0], answer(played, 0)
    assert_equal [width * 3 / 4, (height / 2) + (width / 4), 0], answer(played, 1)
  end

  def test_a_point_behind_the_viewer_or_nearer_than_the_near_limit_lands_nowhere
    played = game_player.run(game([[0.0, 0.0, -1.0], [0.0, 0.0, 0.1]]), frames: 2)

    assert_equal [0, 0, 1], answer(played, 0), "behind the viewer"
    assert_equal [0, 0, 1], answer(played, 1), "nearer than the near limit"
  end

  # A point lands on the first pixel whose middle is at or past it, as a face's corner does. 0.11
  # wholes right at two ahead is 0.0275 of the screen's width right of its middle line: on the
  # Advance's screen 126.6, past the middle of pixel 126 (126.5), so it lands on 127.
  def test_a_point_between_pixels_lands_on_the_first_pixel_whose_middle_is_past_it
    played = game_player.run(game([[0.11, 0.0, 2.0]]), frames: 2)
    across = (played[:width] / 2.0) + (0.0275 * played[:width])

    assert_equal (across - 0.5).ceil, played[:x0]
    assert_equal played[:height] / 2, played[:y0]
  end

  # Where the corner (-1, 1, 2) lands for a viewer turned left by +degrees+, as [x, y], by the
  # same rule: the corner seen along the viewer's arrows, then a quarter of the width for every
  # whole across or up at two ahead.
  private def turned_corner(played, degrees)
    radians = degrees * Math::PI / 180
    across = -Math.cos(radians) + (2 * Math.sin(radians))
    ahead = Math.sin(radians) + (2 * Math.cos(radians))
    half = played[:width] / 2.0
    [(half + (half * across / ahead) - 0.5).ceil, ((played[:height] / 2.0) - (half / ahead) - 0.5).ceil]
  end

  # A viewer turned by angles the game works out, one a pass: fractions of a degree and whole
  # degrees, below nought and past a whole turn (PlaceGames.spins, coming to nought every sixth).
  def test_a_point_lands_where_a_viewer_turned_by_a_worked_out_angle_sees_it
    [false, true].product((2..8).to_a).each do |whole, frames|
      played = game_player.run(PlaceGames.turning_square(draw: false, whole: whole), frames: frames)
      turned = PlaceGames.spins(whole).cycle.take(played[:frame]).sum

      assert_equal turned_corner(played, turned), [played[:x0], played[:y0]], "#{played[:frame]} turns, #{turned} degrees"
    end
  end
end
