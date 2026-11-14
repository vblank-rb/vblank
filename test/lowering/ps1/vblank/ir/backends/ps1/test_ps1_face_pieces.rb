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

  # A picture of 32 by 32 pixels, each its own colour: red counts across and green counts down, so a pixel
  # on the screen says which texel landed there.
  SWIM_SIZE = 32
  SWIM_PICTURE = (0...SWIM_SIZE).flat_map { |down| (0...SWIM_SIZE).map { |across| across | (down << 5) | (1 << 10) } }.freeze

  # A wall down the viewer's left, from just ahead of them to three wholes ahead: the wall the chip's
  # straight stepping bends most, near and at a slant. Its nearness changes across the screen only.
  SIDE_WALL = [[-1.0, 1.5, 0.4], [-1.0, 1.5, 3.0], [-1.0, -1.5, 3.0], [-1.0, -1.5, 0.4]].freeze
  # A floor below the viewer over the same reach, whose nearness changes down the screen only.
  FLOOR = [[-1.5, -1.0, 3.0], [1.5, -1.0, 3.0], [1.5, -1.0, 0.4], [-1.5, -1.0, 0.4]].freeze

  # The face with +corners+ seen by a viewer turning a little left each pass.
  def self.turning(corners, perspective)
    VBlank.game("WALL SWIM", consoles: %i[ps1]) do
      screen :bitmap, tear_free: true
      image :texels, width: SWIM_SIZE, height: SWIM_SIZE, data: SWIM_PICTURE
      place :wall do
        face(*corners.map { |x, y, z| point(x, y, z) }, picture: :texels, on_picture: [[0, 0], [64, 0], [64, 72], [0, 72]])
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        eye.turn :left, by: 0.7
        clear_screen :black
        draw_place :wall, seen_by: eye, perspective: perspective
      end
    end.program(console: :ps1)
  end

  # Each pass's picture of the wall as the chip draws it, set beside the interpreter's exact perspective
  # (worked out at every pixel), texel for texel: at every turn of the view the chip's place on the
  # picture is off by no more than the whole texels it is sent at each corner leave it, two, so the
  # picture does not swim across the wall as the view turns.
  def test_a_near_wall_at_a_slant_keeps_its_picture_within_two_texels_as_the_view_turns
    worst = worst_texels_off(SIDE_WALL)

    assert(worst.drop(1).all? { |texels| texels <= 2 }, "texels off at each pass: #{worst.inspect}")
  end

  # ...and so does a near floor, cut into wide cells where the wall is cut into narrow ones.
  def test_a_near_floor_keeps_its_picture_within_two_texels_as_the_view_turns
    worst = worst_texels_off(FLOOR)

    assert(worst.drop(1).all? { |texels| texels <= 2 }, "texels off at each pass: #{worst.inspect}")
  end

  # The most texels the chip's picture of the face with +corners+ is off the exact one, at each pass:
  # nil for the first, which ends before the face is drawn. The picture repeats every SWIM_SIZE texels,
  # so a texel is off by the shorter way round.
  private def worst_texels_off(corners)
    exact = passes_of(self.class.turning(corners, :every_pixel), nil)
    chip = passes_of(self.class.turning(corners, :every_8_pixels), PS1::CheckedRun::FacesByChip.new(PS1::PolygonFill.new))
    chip.zip(exact).map do |drawn, wanted|
      drawn.zip(wanted).filter_map do |got, want|
        next unless got >> 10 == 1 && want >> 10 == 1

        [got & 31, (got >> 5) & 31].zip([want & 31, (want >> 5) & 31]).map { |a, b| [(a - b) % SWIM_SIZE, (b - a) % SWIM_SIZE].min }.max
      end.max
    end
  end

  # The wall's pixels at each pass of +program+, filled by +filler+ (the interpreter's own fill when nil).
  private def passes_of(program, filler)
    passes = []
    player = VBlank::IR::Backends::Reference.new
    player.fill_faces_with(filler) if filler
    player.each_vblank { passes << (0...240).flat_map { |y| (0...320).map { |x| player.screen.pixel(x, y) } } }
    player.run(program, frames: 8)
    passes
  end

  # A wall at a slant, near at its left and far at its right, so it is cut into many cells.
  SLANTED_WALL = [[16 * 16, 16 * 16, 0, 0, 1 << 24, 0], [300 * 16, 100 * 16, 64 << 16, 0, 1 << 21, 0],
                  [300 * 16, 140 * 16, 64 << 16, 64 << 16, 1 << 21, 0], [16 * 16, 220 * 16, 0, 64 << 16, 1 << 24, 0]].freeze

  private def slanted_wall_triangles(edges)
    FacePieces.triangles(corners: SLANTED_WALL, edges: edges, spans: 8, width: 16, height: 16).map(&:corners)
  end

  # Through a window, a face is sent as the triangles the whole screen sends it as that reach the window,
  # corner for corner, so the chip draws each pixel there as on the whole screen; and the cells wholly
  # outside the window are not made at all. The face is cut straight at the lines around the window, and
  # a corner a cut makes is worked out from the edge it lies on, so it is the corner the cuts along every
  # line before would make.
  def test_a_face_through_a_window_is_sent_as_the_whole_screens_triangles_there
    whole = slanted_wall_triangles([0, 0, 320, 240])

    [[100, 90, 140, 150], [37, 13, 91, 77], [200, 0, 320, 240]].each do |window|
      through = slanted_wall_triangles(window)

      assert_empty through - whole, "triangles through #{window} the whole screen does not send"
      assert_operator through.length, :<, whole.length / 3, "through #{window}"
    end
  end

  # A corner a cut across the screen makes is the same, to the bit, whichever lines the piece was cut at
  # before: cut down the slanted wall a line at a time, the part past each line is the wall cut straight
  # at that line.
  def test_a_cut_makes_the_same_corners_whichever_lines_were_cut_before
    face = SLANTED_WALL.map { |corner| FacePieces.corner_from_list(*corner, 8, 0) }
    rest = face
    (30..210).step(7).each do |y|
      line = y * 16
      rest = FacePieces.cut(rest, FacePieces::Y, line, 8)[1]
      straight = FacePieces.cut(face, FacePieces::Y, line, 8)[1]

      assert_equal(straight.map { |corner| corner.first(FacePieces::NUMBERS) }, rest.map { |corner| corner.first(FacePieces::NUMBERS) }, "at y #{y}")
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
