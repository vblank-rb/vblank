# frozen_string_literal: true

require "test_helper"
require "place_games"

require VBlank.root.join("examples/lit_corridor").to_s

# What the PlayStation sends the graphics chip for a lit face (PS1::FacePieces). The chip shades a lit
# face itself, as the console's own games lit their walls: each triangle's corners carry a colour, and
# the chip multiplies every texel by the colour it steps across the triangle (PS1::PolygonFill, which
# the checked run holds to Beetle PSX every pixel). So a lit face is sent as no more triangles than the
# same face unlit, however many levels its shading has and however steeply its light falls.
class TestPS1FacePieces < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  FacePieces = PS1::FacePieces

  # A face filling much of the screen, its corners [x, y, u, v, w, light] as the corner list holds them
  # (x and y in sixteenths, u and v with sixteen bits of fraction, w the nearness for perspective), lit
  # from nothing at the left to full at the right.
  private def wall(perspective)
    w = perspective ? 1 << 22 : 0
    [[16 * 16, 16 * 16, 0, 0, w, 0], [300 * 16, 16 * 16, 64 << 16, 0, w, 0xFFFF],
     [300 * 16, 220 * 16, 64 << 16, 64 << 16, w, 0xFFFF], [16 * 16, 220 * 16, 0, 64 << 16, w, 0]]
  end

  private def triangles(perspective, levels)
    FacePieces.triangles(corners: wall(perspective), edges: [0, 0, 320, 240],
                         spans: perspective ? 8 : VBlank::IR::Nodes::FillFace::PERSPECTIVE_NONE,
                         width: 16, height: 16, levels: levels)
  end

  # Thirty-two levels, the light crossing every one of them: the same triangles as the face unlit, each
  # corner carrying its colour.
  def test_a_lit_face_is_sent_as_no_more_triangles_than_unlit
    [false, true].each do |perspective|
      lit = triangles(perspective, 32)
      unlit = triangles(perspective, 0)

      assert_equal unlit.length, lit.length, "perspective #{perspective}"
      assert_equal(unlit.map { |each| each.corners.map { |corner| corner.first(4) } }, lit.map { |each| each.corners.map { |corner| corner.first(4) } })
      assert(lit.all?(&:shaded))
      assert(lit.flat_map(&:corners).all? { |corner| corner[4].between?(0, FacePieces::FULL_COLOR) })
    end
  end

  # With eight levels, light nought is level nought, an eighth of the texel's brightness; light a half
  # is level four, five eighths; and the brightest light is the texel as it is.
  def test_a_corners_colour_is_the_brightness_of_the_level_its_light_starts
    colour = lambda do |light|
      FacePieces.corner_color(FacePieces.corner_from_list(0, 0, 0, 0, 0, light, VBlank::IR::Nodes::FillFace::PERSPECTIVE_NONE, 8)[FacePieces::SHADE])
    end

    assert_equal [0x10, 0x50, FacePieces::FULL_COLOR], [colour.call(0), colour.call(0x8000), colour.call(0xFFFF)]
  end

  # The lit corridor's shading darkens evenly over eight levels. Where the interpreter's shading makes a
  # pixel some share of its picture's brightness, the chip makes the pixel it draws there within a level
  # (an eighth) of that share of the texel it reads: the chip's place on the picture is its own, so each
  # is set beside its own picture drawn unlit.
  def test_a_lit_wall_is_within_a_level_of_the_shadings_brightness
    own_lit, own_unlit, chip_lit, chip_unlit = [{}, { lit: false }].flat_map do |settings|
      program = LitCorridor::GAME.program(console: :ps1, settings: settings)
      [VBlank::IR::Backends::Reference.new, VBlank::IR::Backends::Reference.new.fill_faces_with(PS1::CheckedRun::FacesByChip.new(PS1::PolygonFill.new))]
        .map { |player| player.run(program, frames: 2).screen }
    end.values_at(0, 2, 1, 3)
    red = ->(screen, x, y) { screen.pixel(x, y) & 31 }
    pixels = (0...240).step(3).to_a.product((0...320).step(3).to_a).select { |y, x| red.call(own_unlit, x, y) >= 8 && red.call(chip_unlit, x, y) >= 8 }
    far = pixels.reject do |y, x|
      share = red.call(own_lit, x, y).fdiv(red.call(own_unlit, x, y))
      (red.call(chip_lit, x, y) - (red.call(chip_unlit, x, y) * share)).abs <= (red.call(chip_unlit, x, y) / LitCorridor::LEVELS.to_f) + 1
    end

    refute_empty pixels
    assert_operator far.length, :<=, pixels.length / 50, "more than a level away at #{far.first(5)}"
  end

  # The white face of PlaceGames.lit_square, lit from nought at the left to one at the right, goes from a
  # level's worth of white (its shading has four levels, so a quarter) to white, a little brighter every
  # few pixels rather than in the shading's four steps, grey alike in red, green and blue.
  def test_a_face_is_lit_smoothly_by_the_chip
    %i[none every_8_pixels].each do |perspective|
      screen = game_player.run(PlaceGames.lit_square(left: 0.0, right: 1.0, perspective: perspective), frames: 2).screen
      reds = (60..179).map { |x| screen.pixel(x, 80) & 0x1F }

      assert_includes 7..8, reds.first, "#{perspective}: a quarter bright at the left"
      assert_operator reds.last, :>=, 30, "#{perspective}: bright at the right"
      assert_equal reds.sort, reds, "#{perspective}: brighter towards the right"
      assert_operator reds.uniq.length, :>, 16, "#{perspective}: in more steps than the shading's four levels"
      assert((60..179).all? { |x| screen.pixel(x, 80) == (screen.pixel(x, 80) & 0x1F) * 0x0421 }, "#{perspective}: grey")
    end
  end

  # ModTexel: each channel times the colour over 80h, held to 1Fh; 80h is the texel as it is.
  def test_the_chip_multiplies_each_channel_by_the_colour
    color = 0x1F | (0x10 << 5) | (0x02 << 10)

    assert_equal color, PS1::PolygonFill.modulated(color, 0x80)
    assert_equal 0x0F | (0x08 << 5) | (0x01 << 10), PS1::PolygonFill.modulated(color, 0x40)
    assert_equal 0x1F | (0x1F << 5) | (0x03 << 10), PS1::PolygonFill.modulated(color, 0xFF)
    assert_equal 0, PS1::PolygonFill.modulated(color, 0)
  end
end
