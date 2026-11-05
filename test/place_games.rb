# frozen_string_literal: true

# Small games of places made of flat faces, kept once for every console's test of what a place
# draws (test/console/gba/vblank/builder/test_places_on_the_advance.rb,
# test/console/ps1/vblank/builder/test_places_on_the_playstation.rb) and for the test of the
# Advance's cartridge (test/lowering/gba/vblank/builder/test_places_cartridge.rb). Where a comment
# says where something lands, it is on the Advance's screen, 240 by 160.
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

  # The angles turning_square's viewer turns left by, one a turn, round and round: fractions of a
  # degree, below nought and past a whole turn, coming to nought in all.
  SPINS = Ractor.make_shareable([12.5, -372.5, 370.0, -10.0, -0.75, 0.75])

  # The same in whole degrees, past the most a fraction can hold, coming to nought in all. Each
  # list keeps the turn so far between a degree right and thirteen left, so the corner stays on
  # the screen.
  WHOLE_SPINS = Ractor.make_shareable([13, -40_333, 40_330, -10, -1, 1])

  # The angles turning_square turns by, whole or not.
  def self.spins(whole) = whole ? WHOLE_SPINS : SPINS

  # The square face, seen by a viewer that turns left by the next of SPINS (or of WHOLE_SPINS,
  # when +whole+) on every +passes+-th pass, the angle put in a variable the game reads from a
  # table as it runs. Each pass the square's top left corner is asked where it lands, the answer
  # kept in x0 and y0. The first turn swings the corner from the left quarter of the screen
  # towards its middle; after every sixth the viewer faces ahead again, and the corner is back at
  # x 60 and y 20. Without +draw+ the square is only asked about, never drawn, which every
  # console can do.
  def self.turning_square(passes: 1, draw: true, whole: false)
    turns = spins(whole)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true if draw
      image :tile, width: 8, height: 8, data: TILE
      var :width, screen_width
      var :height, screen_height
      corner = nil
      place :wall do
        corner = point(-1.0, 1.0, 2.0)
        face corner, point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
      end
      spins = table :spins, turns, width: :word
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      frame = var :frame, 0
      spin = var :spin, whole ? 0 : 0.0
      x = var :x0, -1
      y = var :y0, -1
      game_loop do
        if (frame % passes) == 0
          spin.store!(spins[(frame / passes) % turns.length])
          eye.turn :left, by: spin
        end
        if draw
          clear_screen :black
          draw_place :wall, seen_by: eye
        end
        spot = screen_spot(:wall, corner, seen_by: eye)
        x.store!(spot.x)
        y.store!(spot.y)
        frame += 1
      end
    end
    builder.finalize_program
    builder.program
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
  #
  # +lit+ lights it from its corners (the last of each corner's numbers) by a small shading.
  def self.moving_five_corners(passes: 1, lit: false)
    numbers = [[100, 20, -3, -2, 1 << 26, 0], [140, 30, 12, -2, 1 << 24, 0x8000], [135, 70, 12, 9, 3 << 23, 0xFFFF],
               [95, 80, -3, 13, 1 << 25, 0x4000], [80, 50, -5, 5, 1 << 27, 0xC000]]
              .flat_map { |x, y, u, v, w, light| [x * 16, y * 16, u << 16, v << 16, w, light] }
    builder = VBlank::Builder.new
    builder.instance_eval do
      b = VBlank::IR::Build
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      image(:stripes, "r" => :red, "w" => :white) { "rw\nrw\n" }
      # The stripes darken in the dimmer half of the light; the tile's colours are not the
      # shading's, so they stay as they are.
      shading :dim, colors: [rgb(31, 31, 31), rgb(31, 0, 0), rgb(16, 16, 16), rgb(16, 0, 0)],
                    levels: [[2, 3, 2, 3], [0, 1, 2, 3]]
      corners = list :corners, capacity: 48, full_of: 0
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
                           perspective: perspective, shading: lit ? :dim : nil))
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
  # Drawn with +perspective+. +asked_first+ asks where its corners land first, with a near limit nearer
  # than the drawing's, and +drawn_straight_first+ draws it without perspective first, the same pass:
  # both turn its points before the drawing, which reads them. +console+ is the console it is built for
  # (none, the unbound program a test plays as each run's console).
  def self.wall_down_the_side(perspective, asked_first: false, drawn_straight_first: false, console: nil)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
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
        4.times { |corner| screen_spot :side, corner, seen_by: eye, near: 0.01 } if asked_first
        draw_place :side, seen_by: eye, perspective: :none if drawn_straight_first
        draw_place :side, seen_by: eye, perspective: perspective
      end
    end
    builder.finalize_program
    builder.program
  end

  # The four colours of a small shading, and its four levels, darkest first: white goes black at
  # the darkest level, then dark gray, then gray, and is itself at the brightest.
  SHADES = Ractor.make_shareable([0x7FFF, 0x4210, 0x2108, 0x0000])
  SHADE_LEVELS = Ractor.make_shareable([[3, 3, 3, 3], [2, 2, 2, 3], [1, 1, 2, 3], [0, 1, 2, 3]])

  # The square face (x 60 to 179, y 20 to 139) all white, lit by the shading, its left corners'
  # light +left+ and its right corners' +right+, and +added+ added to every point's light as the
  # game runs (a lamp the game turns up). +see_through+ leaves every third pixel of the picture
  # out, and +far+ is how far ahead its right side is.
  def self.lit_square(left:, right:, added: 0.0, perspective: :none, see_through: false, far: 2.0)
    clear = see_through ? 0x001F : nil
    pixels = Array.new(64) { |at| see_through && (at % 3).zero? ? clear : 0x7FFF }
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :white, width: 8, height: 8, data: pixels, transparent: clear
      shading :fade, colors: SHADES, levels: SHADE_LEVELS
      wall = place :wall, shading: :fade do
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, far), point(1.0, -1.0, far), point(-1.0, -1.0, 2.0),
             picture: :white, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]], light: [left, right, right, left]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        4.times { |point| wall.point_lights[point] = added }
        clear_screen :black
        draw_place :wall, seen_by: eye, perspective: perspective
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

  # The square face drawn twice a pass, by a viewer that moves between: from the middle, held to the
  # left half of the screen, so it covers x 60 to 119 there; then from half a whole to the left, held
  # to the right half, where it lands 30 pixels further right and covers x 120 to 209. A drawing that
  # sees the place as the last one did reads the points that one turned (IR::PlaceDrawing::TURN_PARTS),
  # so one that turned none afresh after the viewer moved would draw the second where the first was,
  # up to x 179.
  def self.seen_from_two_spots
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      place :wall do
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        eye.at 0.0, 0.0, 0.0
        draw_place :wall, seen_by: eye, window: [0, 0, 120, 160]
        eye.at(-0.5, 0.0, 0.0)
        draw_place :wall, seen_by: eye, window: [120, 0, 240, 160]
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

  # The three pictures a door goes through, a colour each, and the order the game shows them in: a
  # number not one of the place's pictures (-1) is passed over, so the door stays blue for it.
  DOOR_COLORS = Ractor.make_shareable(%i[red green blue])
  DOOR_STEPS = Ractor.make_shareable([0, 1, 2, -1])

  # A door on the left and a wall of the tile on the right. Every +passes+ passes the game points the
  # door's slot at the next picture of DOOR_STEPS (red, green, blue, then a number it passes over),
  # worked out as it runs; the wall's slot is never changed. The pass the door showed is kept in
  # `drawn`, so a test can say which colour the screen should show.
  # +named+ instead points the slot once, before the loop, at the picture named :door2 (blue).
  def self.changing_door(passes: 3, named: false)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: TILE
      DOOR_COLORS.each_with_index do |color, k|
        image(:"door#{k}", "#" => color) { "##\n##\n" }
      end
      hall = place :hall do
        pictures :door0, :door1, :door2
        face point(-3.0, 1.0, 4.0), point(-1.0, 1.0, 4.0), point(-1.0, -1.0, 4.0), point(-3.0, -1.0, 4.0),
             picture: :door0, on_picture: [[0, 0], [2, 0], [2, 2], [0, 2]]
        face point(1.0, 1.0, 4.0), point(3.0, 1.0, 4.0), point(3.0, -1.0, 4.0), point(1.0, -1.0, 4.0),
             picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
      end
      steps = table :door_steps, DOOR_STEPS, width: :word
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      pass = var :pass, 0
      drawn = var :drawn, -1
      change_picture :hall, slot: :door0, to: :door2 if named
      game_loop do
        unless named
          step = steps[(pass / passes) % DOOR_STEPS.length]
          change_picture :hall, slot: :door0, to: step + hall.picture_number(:door0)
        end
        clear_screen :black
        draw_place :hall, seen_by: eye
        drawn.store!(pass)
        pass += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # The colour the door shows on pass +pass+ of changing_door(passes:): the step's own, or for a
  # step passed over, the last one shown before it.
  def self.door_color(pass, passes: 3)
    k = (pass / passes) % DOOR_STEPS.length
    k -= 1 while DOOR_STEPS[k].negative?
    DOOR_COLORS[DOOR_STEPS[k]]
  end
end
