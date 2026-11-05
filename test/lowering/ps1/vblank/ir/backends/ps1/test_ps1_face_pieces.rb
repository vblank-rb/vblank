# frozen_string_literal: true

require "test_helper"
require "place_games"

# What the PlayStation sends the graphics chip for a lit face (PS1::FacePieces), drawn by the chip's
# rules (PS1::CheckedRun's faces, which the checked run holds to Beetle PSX every pixel), set beside the
# interpreter's own fill of the same face. The chip draws each piece of a lit face through the colour
# table of one level of the game's shading, so its picture is the shading's own colours, and it can
# differ from the interpreter's only where the light passes from one level to the next.
class TestPS1FacePieces < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  Reference = VBlank::IR::Backends::Reference

  # Inside the face of PlaceGames.lit_square (x 60 to 179, y 20 to 139), a pixel in from its edges,
  # where the chip's own rule for a face's edges does not come into it.
  FACE_ROWS = 21...139
  FACE_COLUMNS = 61...179

  private def pictures(perspective, left: 0.0, right: 1.0)
    game = PlaceGames.lit_square(left: left, right: right, perspective: perspective)
    own = Reference.new.run(game, frames: 2).screen
    by_chip = Reference.new.fill_faces_with(PS1::CheckedRun::FacesByChip.new(PS1::PolygonFill.new))
                       .run(game, frames: 2).screen
    [own, by_chip]
  end

  def test_a_lit_face_differs_from_the_interpreters_only_beside_a_line_between_two_levels
    %i[none every_8_pixels].each do |perspective|
      own, by_chip = pictures(perspective)
      differing = FACE_ROWS.to_a.product(FACE_COLUMNS.to_a).reject { |y, x| own.pixel(x, y) == by_chip.pixel(x, y) }
      levels = FACE_COLUMNS.map { |x| own.pixel(x, 80) }.uniq

      assert_equal 4, levels.length, "#{perspective}: the face shows every level of the shading"
      differing.each do |y, x|
        beside = [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]].map { |at| own.pixel(*at) }

        assert_includes beside, by_chip.pixel(x, y), "#{perspective}: (#{x}, #{y}) is a level away from a line"
      end
      assert_operator differing.length, :<=, FACE_ROWS.size * 3, "#{perspective}: at most a pixel a row along each line"
    end
  end

  # The interpreter gives a pixel its level from the shade where the pixel starts. Lit evenly from
  # nought at the left to one at the right, each of the four levels covers 30 pixels, and the light
  # reaching just under one puts each line a hair past its pixel: the next level starts at x 91, 121
  # and 151. Without FacePieces::LEVEL_LINE_NUDGE the chip's lines would fall a pixel left, at 90.
  # The same with the light falling from the left to the right: the lines are where the interpreter's are.
  def test_the_lines_between_levels_fall_where_the_interpreters_do
    [[0.0, 1.0], [1.0, 0.0]].product(%i[none every_8_pixels]).each do |(left, right), perspective|
      own, by_chip = pictures(perspective, left: left, right: right)

      [21, 80, 138].each do |y|
        assert_equal FACE_COLUMNS.map { |x| own.pixel(x, y) }, FACE_COLUMNS.map { |x| by_chip.pixel(x, y) }, "#{perspective}: row #{y}"
        [91, 121, 151].each { |x| refute_equal own.pixel(x - 1, y), own.pixel(x, y), "#{perspective}: a line at #{x}" }
      end
    end
  end
end
