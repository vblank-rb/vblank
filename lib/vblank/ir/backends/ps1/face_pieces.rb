# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT THE PROCESSOR SENDS THE GRAPHICS CHIP FOR ONE FACE OF A PLACE, worked out in Ruby the way
        # Runtime::Faces works it out in MIPS, number for number. The runtime is held to this: the
        # PlayStation's checked run draws what these triangles make, by the chip's own rules
        # (PS1::PolygonFill), and compares that with what the chip drew in the emulator,
        # every pixel. So this file is the plain statement of the routine, and the MIPS is the same
        # sums again.
        #
        # WHY A FACE IS CUT BEFORE THE CHIP SEES IT. The chip fills a textured triangle by itself, fast,
        # but it has limits the interpreter's fill does not have:
        #
        # - a corner is a whole pixel, at most 1023 pixels across from the others and 511 down, or the
        #   chip leaves the triangle out (psx-spx, "GPU Render Polygon Commands"); and a face cut at the
        #   near limit has corners up to 2048 pixels off the screen;
        # - a corner's place on the picture is a byte each way, 0 to 255, and the chip steps straight
        #   from one corner's to the next with no wrap of its own;
        # - it has no perspective: the place on the picture steps evenly across the triangle.
        #
        # So the face is cut, on the processor, into pieces the chip can draw:
        #
        # 1. CLIPPED to its edges (`window:`, `inside`, the screen): every corner then lies on the
        #    screen. The chip's drawing area is set to the same edges, so its pixels stop there too. A
        #    face without perspective already on the screen is not clipped (#sent_unclipped?): the
        #    drawing area alone holds it to its edges. Nor is one in perspective inside its edges, which
        #    the cuts would leave as it is.
        # 2. IN PERSPECTIVE, CUT INTO SQUARES, along rows and columns from its top left corner, their side
        #    the face's own (#cell_side_shift): small where it is near and at a slant, and none at all for
        #    most faces far off or seen straight on. Each new corner's place on the picture is worked out
        #    exactly (the place over the distance, times the distance, as Reference#place_in_perspective
        #    does), and the chip steps straight between. That is how the console's own games drew a near
        #    wall. The face is cut into strips along its rows' lines (#each_strip), and each strip into
        #    squares by walking its edges across it (#each_square_in_strip), not by cutting it again.
        # 3. CUT WHERE THE PICTURE WOULD RUN PAST A BYTE: a piece whose place on the picture spans more
        #    than 256 is cut at 256 past its least, as often as it takes. The picture repeats by the
        #    chip's texture window (GP0 E2h), so each piece's places are moved by whole pictures to
        #    start between 0 and the picture's size.
        # 4. SENT as a fan of triangles from the piece's first corner, each corner rounded to the
        #    nearest whole pixel; a triangle with no area is left out (the chip draws nothing of one).
        #
        # A FACE LIT BY A SHADING IS SHADED BY THE CHIP, as the console's own games lit their walls: each
        # corner of a triangle carries a colour, the chip steps it across the triangle as it steps the
        # place on the picture, and multiplies each texel's red, green and blue by it (GP0 34h, a shaded
        # textured triangle; 80h is the texel as it is, nought is black). A corner's colour comes from its
        # light, as bright as a shading that darkens evenly makes the level the light starts
        # (#light_floor, #corner_color). So a lit face is cut no more than an unlit one, however many
        # levels its shading has and however steeply its light falls across it. Between the corners the
        # light changes smoothly, not a level at a time, so a pixel is within a level of the brightness
        # the shading gives it; and the chip scales red, green and blue alike, so a shading that does
        # anything else to a colour than darken it (a tint, a fog) is drawn as the colour darkened.
        #
        # A corner is NUMBERS numbers, by these places: X and Y, in sixteenths of a pixel; U_SOURCE,
        # V_SOURCE and NEARNESS, what the place on the picture is worked out from (without perspective
        # u and v themselves, with sixteen fraction bits, and no nearness; in perspective u and v over
        # the distance and one over the distance, as Reference::FaceEdges.in_perspective has them);
        # TEXEL_U, TEXEL_V, the whole texel the corner sends; and SHADE, a lit face's colour with sixteen
        # bits of fraction (#corner_from_list), and nought on a face that is not lit. Every sum is IR::Int32's,
        # so it wraps where the processor's does.
        #
        # WHERE A CUT CROSSES AN EDGE, the new corner is worked out once, from the end of the edge
        # below the line towards the end above it, and given to both sides; so the two pieces on either
        # side of a line share their corners to the bit and the chip leaves no crack between them.
        module FacePieces
          X = 0
          Y = 1
          U_SOURCE = 2
          V_SOURCE = 3
          NEARNESS = 4
          TEXEL_U = 5
          TEXEL_V = 6
          SHADE = 7
          NUMBERS = 8
          # The numbers a cut across the screen steps (#corner_between): x and y (the one cut on is then
          # the line), and what the texel is worked out from; the texel is worked out afresh.
          SCREEN_CUT_NUMBERS = [X, Y, U_SOURCE, V_SOURCE, NEARNESS, SHADE].freeze
          # The numbers a cut on the picture steps.
          LATE_CUT_NUMBERS = [X, Y, TEXEL_U, TEXEL_V, SHADE].freeze

          # A corner's colour at the brightest light: the texel as it is (#corner_color).
          FULL_COLOR = 0x80

          # The most corners a piece keeps: a face's eight, one more for each of the four clipping
          # edges, the two lines of a square it is cut by each way and a cut each way on the picture,
          # with room over. A face that is not flat can cross a line more often than a flat one; past
          # this many, a piece keeps its first ones.
          MOST_CORNERS = 24

          # The sides a square a face in perspective is cut into may have, as powers of two of pixels
          # (#cell_side_shift): from the least, a square of 8, to the most, 512, which is wider than the
          # screen, so a face given it is not cut at all.
          LEAST_CELL_SHIFT = 3
          MOST_CELL_SHIFT = 9

          # How far the place on the picture a square shows may be off on the screen (#cell_side_shift), as
          # a power of two of pixels: two pixels, and one for a face the interpreter works out at every
          # pixel.
          OFF_PIXELS_SHIFT = 1
          EVERY_PIXEL_OFF_PIXELS_SHIFT = 0

          # The relative change in nearness across a face (#nearness_change) is kept with this many bits
          # of fraction, and held to MOST_NEARNESS_CHANGE, sixteen times its least: a face changing that
          # much across is cut into the least squares on any screen.
          NEARNESS_CHANGE_BITS = 8
          MOST_NEARNESS_CHANGE = 16 << NEARNESS_CHANGE_BITS

          # Must hold for #cell_side_shift: the change times the most side's square stays a positive word,
          # and a face whose change is held to the most is cut into the least squares however big it is
          # on the screen, so holding it changes no side.
          raise "the nearness change overflows a word" unless (MOST_NEARNESS_CHANGE << (2 * MOST_CELL_SHIFT)) < (1 << 31)
          unless (MOST_NEARNESS_CHANGE << (2 * (LEAST_CELL_SHIFT + 1))) >
                 ((Console::PLAYSTATION.screen_size.min * 16) << (NEARNESS_CHANGE_BITS + 2 - 4 + OFF_PIXELS_SHIFT))
            raise "a face whose nearness change is held is not cut into the least squares"
          end

          # The bits of fraction in the share of an edge a cut is along.
          SHARE_BITS = 14

          # How many pieces can wait to be cut on the picture at once. Past this, a further one is left
          # out, as the runtime's room for them is.
          MOST_WAITING = 8

          # How far a piece's place on the picture may run: a byte's worth past its least.
          PICTURE_REACH = 256

          # The screen every PlayStation build draws on, in pixels.
          SCREEN_WIDTH, SCREEN_HEIGHT = Console::PLAYSTATION.screen_size

          # One triangle as the chip is sent it: three corners [x, y, u, v], x and y whole pixels on the
          # screen, u and v the texel in the picture's page, and on a lit face (+shaded+) a fifth, the
          # corner's colour (#corner_color).
          Triangle = Data.define(:corners, :shaded)

          module_function

          # The triangles one face is sent as, in the order they are sent: +corners+ the face's corners as
          # the list holds them ([x, y, u, v, w, light] each), +edges+ [left, top, right, bottom] already
          # held to the screen and the area drawing is held to, +spans+ the face's perspective, the
          # picture's +width+ and +height+, and the +levels+ of the shading it is lit by (nought: not lit;
          # how many there are does not matter to the chip's shading).
          def triangles(corners:, edges:, spans:, width:, height:, levels: 0)
            left, top, right, bottom = edges
            return [] if left >= right || top >= bottom

            face = corners.map { |corner| corner_from_list(*corner.first(Nodes::FillFace::CORNER_NUMBERS), spans, levels) }
            unless sent_unclipped?(face, spans, edges)
              face = keep_side(face, X, Int32.mul(left, 16), :above, spans)
              face = keep_side(face, X, Int32.mul(right, 16), :below, spans)
              face = keep_side(face, Y, Int32.mul(top, 16), :above, spans)
              face = keep_side(face, Y, Int32.mul(bottom, 16), :below, spans)
            end
            return [] if face.length < 3

            sent = []
            each_cell(face, spans) { |piece| send_cut_on_picture(piece, width, height, levels, sent) }
            sent
          end

          # Whether +face+ is sent without being clipped to its +edges+ (step 1 of the module's note).
          #
          # A face without perspective whose corners are all on the screen: every triangle of it is well
          # inside what the chip draws, and the chip's drawing area, set to the same edges, holds its pixels
          # to them, as the console's own games left a polygon on the screen to the chip. Clipping it on the
          # processor first costs a cut for each edge, and gives more corners, so more triangles, to send.
          #
          # A face in perspective whose corners all lie inside its edges: clipping it would keep every
          # corner and make none, so the four cuts are left out and the pieces are the same. One reaching
          # past an edge is clipped, since its squares start at its own least corner (#each_cell), and
          # squares wholly outside the edges would be cut and sent for the drawing area to throw away.
          def sent_unclipped?(face, spans, edges)
            left, top, right, bottom = edges
            bounds = if spans == Nodes::FillFace::PERSPECTIVE_NONE
                       [[X, 0, SCREEN_WIDTH], [Y, 0, SCREEN_HEIGHT]]
                     else
                       [[X, left, right], [Y, top, bottom]]
                     end
            bounds.all? do |number, low, high|
              least, most = face.map { |corner| corner[number] }.minmax
              least >= low * 16 && most <= high * 16
            end
          end

          # HOW BIG THE SQUARES ARE THAT A FACE IN PERSPECTIVE IS CUT INTO: the side, as a power of two of
          # pixels, from LEAST_CELL_SHIFT to MOST_CELL_SHIFT, for +face+ as clipped.
          #
          # The chip steps the place on the picture straight across a square, where the true place steps
          # with one over the nearness; so the square shows its picture shifted most where the nearness
          # changes most across it, and the more the bigger it is. Nearness changes evenly across the
          # screen, so on a face whose nearness changes by a share c of its least across e pixels, a square
          # of side s shows its picture off by at most about s * s * c / (4 * e) pixels, at the face's far
          # side. e is the face's lesser reach, across or down: the nearness changes across one way or the
          # other, and taking the shorter can only cut the face more finely than it needs. A square reaches
          # no further across the face than the face does, so a face that is off by no more than allowed
          # whole, e * c / 4, is not cut at all, however big its squares would be: most of a place's
          # faces, a few pixels big or far off.
          #
          # So the side is the biggest that keeps that within OFF_PIXELS_SHIFT's pixels. A near wall at a
          # slant is cut into small squares, each of which then shows its part of the picture where it lies
          # and not a few pixels across, so the picture holds still on the wall as the view turns; a far
          # face, or one seen straight on, whose nearness hardly changes across it, into a few big ones or
          # none. That is how the console's own games cut a polygon: by how far its depth reaches and how big
          # it is on the screen, more pieces only where the depth changes most, not a grid fixed on the
          # screen.
          #
          # Every sum is IR::Int32's, and powers of two are shifts, as the runtime has them
          # (rt_face_cell_side, Runtime::Faces#emit_cell_side_routine): the side is halved while s * s * c is more than
          # 4 * e times the pixels allowed, c with NEARNESS_CHANGE_BITS of fraction and e in sixteenths.
          def cell_side_shift(face, spans)
            across = Int32.sub(*face.map { |corner| corner[X] }.minmax.reverse)
            down = Int32.sub(*face.map { |corner| corner[Y] }.minmax.reverse)
            off = spans == 1 ? EVERY_PIXEL_OFF_PIXELS_SHIFT : OFF_PIXELS_SHIFT
            reach = [across, down].min
            change = nearness_change(face)
            shift = MOST_CELL_SHIFT
            return shift if Int32.mul(change, reach) <= Int32.shift_left(1, NEARNESS_CHANGE_BITS + 2 + 4 + off)

            bound = Int32.shift_left(reach, NEARNESS_CHANGE_BITS + 2 - 4 + off)
            shift -= 1 while shift > LEAST_CELL_SHIFT && Int32.shift_left(change, 2 * shift) > bound
            shift
          end

          # How much the nearness changes across +face+, as a share of its least, with NEARNESS_CHANGE_BITS
          # of fraction and held to MOST_NEARNESS_CHANGE: the most less the least, over the least moved down
          # by those bits (one at the least).
          def nearness_change(face)
            least, most = face.map { |corner| corner[NEARNESS] }.minmax
            over = [Int32.shift_right(least, NEARNESS_CHANGE_BITS), 1].max
            [Int32.div(Int32.sub(most, least), over), MOST_NEARNESS_CHANGE].min
          end

          # The corner a face's corner becomes (see the module's note). On a lit face (+levels+ not nought)
          # its shade is its colour with sixteen bits of fraction: its light held to nought to
          # FillFace::LIGHTEST, times FULL_COLOR, and the light floor added (#light_floor).
          def corner_from_list(x, y, u, v, w, light, spans, levels)
            shade = levels.zero? ? 0 : Int32.add(Int32.shift_left(light.clamp(0, Nodes::FillFace::LIGHTEST), 7), light_floor(levels))
            corner = if spans == Nodes::FillFace::PERSPECTIVE_NONE
                       [x, y, u, v, 0, 0, 0, shade]
                     else
                       [x, y, Int32.mul_fix(u, w, 28), Int32.mul_fix(v, w, 28), w, 0, 0, shade]
                     end
            set_texel!(corner, spans)
          end

          # The whole texel at +corner+, into its u and v: without perspective u and v's whole parts; in
          # perspective the place over the distance times the distance (Reciprocals.distance).
          def set_texel!(corner, spans)
            if spans == Nodes::FillFace::PERSPECTIVE_NONE
              corner[TEXEL_U] = Int32.shift_right(corner[U_SOURCE], 16)
              corner[TEXEL_V] = Int32.shift_right(corner[V_SOURCE], 16)
            else
              distance = Reciprocals.distance(corner[NEARNESS])
              corner[TEXEL_U] = Int32.shift_right(Int32.mul_fix(corner[U_SOURCE], distance, 14), 16)
              corner[TEXEL_V] = Int32.shift_right(Int32.mul_fix(corner[V_SOURCE], distance, 14), 16)
            end
            corner
          end

          # +piece+ cut at +line+ on +number+, and the side :above (number at or past the line) or :below
          # (at or before it) kept.
          def keep_side(piece, number, line, side, spans)
            below, above = cut(piece, number, line, spans)
            side == :above ? above : below
          end

          # +piece+ cut at +line+ on +number+ (X or Y: a line across the screen; TEXEL_U or TEXEL_V: a line on the
          # picture): [the part at or before the line, the part at or past it]. A corner on the line is
          # in both. +spans+ sets how a corner made on a screen line has its texel worked out.
          def cut(piece, number, line, spans)
            below = []
            above = []
            piece.each_with_index do |from, at|
              to = piece[(at + 1) % piece.length]
              from_side = Int32.sub(from[number], line)
              to_side = Int32.sub(to[number], line)
              add_corner(below, from) unless from_side.positive?
              add_corner(above, from) unless from_side.negative?
              next unless (from_side.negative? && to_side.positive?) || (from_side.positive? && to_side.negative?)

              made = corner_between(from, to, from_side, to_side, number, line, spans)
              add_corner(below, made)
              add_corner(above, made)
            end
            [below, above]
          end

          def add_corner(piece, corner) = (piece << corner if piece.length < MOST_CORNERS)

          # Where the edge from +from+ to +to+ crosses the line: every number stepped the same share of the
          # way along from the end below the line, the share with SHARE_BITS of fraction; then the number
          # cut on set to the line itself, and, for a line across the screen, the texel worked out there.
          #
          # Only what is read again is stepped, the rest left as the start's. On a line across the screen
          # the texel is worked out afresh, so it is not stepped (SCREEN_CUT_NUMBERS). A cut on the picture
          # comes after every cut across the screen, so nothing reads U_SOURCE, V_SOURCE or NEARNESS again
          # (LATE_CUT_NUMBERS). Each multiply left out is one the runtime spares a corner.
          def corner_between(from, to, from_side, to_side, number, line, spans)
            start, finish, start_side, finish_side = from_side.negative? ? [from, to, from_side, to_side] : [to, from, to_side, from_side]
            share = Int32.div(Int32.shift_left(Int32.sub(0, start_side), SHARE_BITS), Int32.sub(finish_side, start_side))
            stepped = [X, Y].include?(number) ? SCREEN_CUT_NUMBERS : LATE_CUT_NUMBERS
            made = Array.new(NUMBERS) do |part|
              next start[part] unless stepped.include?(part)

              Int32.add(start[part], Int32.mul_fix(Int32.sub(finish[part], start[part]), share, SHARE_BITS))
            end
            made[number] = line
            [X, Y].include?(number) ? set_texel!(made, spans) : made
          end

          # Each piece of +face+ in turn: the face itself without perspective; in perspective, the face cut
          # along a row's line every square's side (#cell_side_shift) from its top corner, top down, and
          # each strip into its squares along the columns' lines from its leftmost corner, left to right
          # (#each_square_in_strip).
          #
          # THE SQUARES START AT THE FACE'S OWN CORNER, not at the screen's: a face of a far room is a
          # few squares wide, and lined up on the screen it would cross a line wherever it fell,
          # however small, and be sent in two pieces or four. Every strip of a face is cut along the
          # same columns, so a corner made on the line between two strips is a corner of the pieces on
          # both sides, and the chip leaves no crack between them.
          def each_cell(face, spans, &block)
            return yield(face) if spans == Nodes::FillFace::PERSPECTIVE_NONE

            side = Int32.shift_left(1, cell_side_shift(face, spans) + 4)
            left = face.map { |corner| corner[X] }.min
            top = face.map { |corner| corner[Y] }.min
            each_strip(face, Y, side, top, spans) { |strip| each_square_in_strip(strip, side, left, spans, &block) }
          end

          # +piece+ cut along every line of +number+ +start+ and a multiple of +side+ on, strictly inside
          # it, the part before each line in turn, then the rest. +start+ is at or before the piece's
          # least. A part of fewer than three corners is left out.
          def each_strip(piece, number, side, start, spans)
            least, most = piece.map { |corner| corner[number] }.minmax
            line = first_line(least, start, side)
            rest = piece
            while line < most
              part, rest = cut(rest, number, line, spans)
              yield part if part.length >= 3
              line = Int32.add(line, side)
            end
            yield rest if rest.length >= 3
          end

          # The first line, +start+ and a multiple of +side+ on, strictly past +least+.
          def first_line(least, start, side) = Int32.add(Int32.add(start, Int32.bit_and(Int32.sub(least, start), Int32.sub(0, side))), side)

          # THE SQUARES OF ONE STRIP of a face (a part between two of its rows' lines), left to right: the
          # parts #each_strip cuts it into along the columns' lines, made without cutting.
          #
          # WHY. A cut walks every corner of the piece it cuts and writes two new pieces, and cutting each
          # strip into squares that way, column by column, was most of what drawing a near wall cost. But a
          # strip is two runs of corners from its least x to its most, one each way round, x rising along
          # both (#strip_chains): its square between two lines is the corners of each run between them and
          # the two places each run crosses the lines. So each run is walked once across the strip
          # (ChainWalk), each line's crossing made once, and each square put together from them in the order
          # the strip's corners go round.
          #
          # A crossing is the corner the cut along that line would make: stepped (#corner_between) from the
          # last crossing on the same edge, or from the edge's first corner, to its other; a corner on the
          # line is the crossing itself. So the pieces either side of a line share their corners, and the
          # strips above and below, whose edges these are too, make the same ones.
          #
          # Each square's left side is the two runs' last crossings, the run going back's first, and the
          # first square's is the two runs' first corners: the strip's two corners at its least x, or its
          # one corner there twice (whose two triangles' first has no area, and is not sent). So every
          # square of four corners is two crossings and the two made from them, which the runtime sends
          # without putting the square together (Runtime::Faces#emit_four_corner_square). A strip no line
          # crosses is one square, sent as it is; one whose runs do not both rise (it is not flat, and
          # doubles back), or with more than two corners at its least, is cut as #each_strip cuts it.
          def each_square_in_strip(strip, side, left, spans)
            least, most = strip.map { |corner| corner[X] }.minmax
            line = first_line(least, left, side)
            return yield(strip) unless line < most

            chains = strip_chains(strip)
            return each_strip(strip, X, side, left, spans) { |square| yield square } unless chains

            forward = ChainWalk.new(chains.forward)
            backward = ChainWalk.new(chains.backward)
            left_side = [chains.backward[0], chains.forward[0]]
            while line < most
              ahead, ahead_crossing = forward.cross(line, spans)
              behind, behind_crossing = backward.cross(line, spans)
              square = left_side + ahead + [ahead_crossing, behind_crossing] + behind.reverse
              yield square.first(MOST_CORNERS) if square.length >= 3
              left_side = [behind_crossing, ahead_crossing]
              line = Int32.add(line, side)
            end
            square = left_side + forward.rest + chains.most_run + backward.rest.reverse
            yield square.first(MOST_CORNERS) if square.length >= 3
          end

          # A strip's corners from its least x to its most (#strip_chains): the run from the last corner at
          # its least on round to the first at its most (+forward+), the run from the first at its least the
          # other way round to the last at its most (+backward+), each taking in its two ends, and those at
          # its most in order round.
          StripChains = Data.define(:forward, :backward, :most_run)

          # THE TWO RUNS OF +strip+ FROM ITS LEAST X TO ITS MOST, or nil where x does not rise strictly
          # along both, or more than two corners are at its least (#each_square_in_strip). Where two
          # corners share the least x (a strip whose left side is upright), the runs start at the two of
          # them; where several share the most, they end at the two ends of those. The corners at the least
          # are found from the first in the strip's order whose corner before is not at the least.
          def strip_chains(strip)
            xs = strip.map { |corner| corner[X] }
            least, most = xs.minmax
            return if least == most

            first_least = (0...xs.length).find { |at| xs[at] == least && xs[at - 1] != least }
            last_least = end_of_run(xs, first_least)
            return if run_between(strip, first_least, last_least).length > 2

            forward, first_most = rising_run(strip, xs, last_least, 1, most)
            backward, reached = rising_run(strip, xs, first_least, -1, most)
            return unless forward && backward

            last_most = end_of_run(xs, first_most)
            return unless reached == last_most

            StripChains.new(forward: forward, backward: backward, most_run: run_between(strip, first_most, last_most))
          end

          # Where the run of corners at the x of +xs+[+from+] ends, going on round from +from+.
          def end_of_run(xs, from)
            at = from
            at = (at + 1) % xs.length while xs[(at + 1) % xs.length] == xs[from] && (at + 1) % xs.length != from
            at
          end

          # The corners of +strip+ from +from+ round by +step+ (1 or -1) while x rises, to the first at
          # +most+, and where that one is in the strip; nil when x stops rising first.
          def rising_run(strip, xs, from, step, most)
            run = [strip[from]]
            at = from
            until xs[at] == most
              following = (at + step) % xs.length
              return unless xs[following] > xs[at]

              run << strip[following]
              at = following
            end
            [run, at]
          end

          # The corners of +strip+ from +from+ on round to +to+.
          def run_between(strip, from, to)
            run = [strip[from]]
            run << strip[from = (from + 1) % strip.length] until from == to
            run
          end

          # ONE RUN OF A STRIP (StripChains) walked across it, a column's line at a time.
          class ChainWalk
            def initialize(corners)
              @corners = corners
              @at = 1 # The first corner not yet passed
              @start = corners[0] # Where the edge being crossed is stepped from
            end

            # The corners passed before +line+, and the corner the run crosses it at: the one on it, or one
            # made on the edge reaching past it, stepped from the last crossing on that edge or its first
            # corner (FacePieces.corner_between).
            def cross(line, spans)
              passed = []
              while @corners[@at][X] < line
                @start = @corners[@at]
                passed << @start
                @at += 1
              end
              finish = @corners[@at]
              if finish[X] == line
                @at += 1
                @start = finish
              else
                @start = FacePieces.corner_between(@start, finish, Int32.sub(@start[X], line), Int32.sub(finish[X], line),
                                                   X, line, spans)
              end
              [passed, @start]
            end

            # The corners not yet passed, short of the last, which is at the strip's most.
            def rest = @corners[@at...-1]
          end

          # +piece+ cut on the picture until each part's places run no more than PICTURE_REACH across and
          # down, and each part sent (see the module's note). The part past a cut waits while the part
          # before it is finished.
          def send_cut_on_picture(piece, width, height, levels, sent)
            waiting = [piece]
            until waiting.empty?
              part = waiting.pop
              while part.length >= 3
                number, line = find_picture_cut(part, width, height)
                unless number
                  send_fan(part, width, height, levels, sent)
                  break
                end

                part, past = cut(part, number, line, nil)
                waiting << past if waiting.length < MOST_WAITING
              end
            end
          end

          # Where +piece+ is cut on the picture, [TEXEL_U or TEXEL_V, the line], or nil when it need not be: across
          # first, at PICTURE_REACH past its least place moved down to a whole picture.
          def find_picture_cut(piece, width, height)
            [[TEXEL_U, width], [TEXEL_V, height]].each do |number, size|
              least, most = piece.map { |corner| corner[number] }.minmax
              base = Int32.bit_and(least, Int32.sub(0, size))
              return [number, Int32.add(base, PICTURE_REACH)] if Int32.sub(most, base) > PICTURE_REACH
            end
            nil
          end

          # +piece+ as a fan of triangles from its first corner, its places moved by whole pictures to
          # start between nought and the picture's size, each held to a byte. On a lit face (+levels+ not
          # nought) each corner carries its colour.
          def send_fan(piece, width, height, levels, sent)
            u_base = Int32.bit_and(piece.map { |corner| corner[TEXEL_U] }.min, Int32.sub(0, width))
            v_base = Int32.bit_and(piece.map { |corner| corner[TEXEL_V] }.min, Int32.sub(0, height))
            shaded = !levels.zero?
            sent_corners = piece.map do |corner|
              [Int32.shift_right(Int32.add(corner[X], 8), 4), Int32.shift_right(Int32.add(corner[Y], 8), 4),
               [Int32.sub(corner[TEXEL_U], u_base), 255].min, [Int32.sub(corner[TEXEL_V], v_base), 255].min,
               *(shaded ? [corner_color(corner[SHADE])] : [])]
            end
            (1...(sent_corners.length - 1)).each do |at|
              triangle = [sent_corners[0], sent_corners[at], sent_corners[at + 1]]
              sent << Triangle.new(corners: triangle, shaded: shaded) unless doubled_signed_area(triangle).zero?
            end
          end

          # The colour a corner of +shade+ (#corner_from_list) is sent with, the same for red, green and
          # blue: its whole part, held to FULL_COLOR.
          def corner_color(shade) = [Int32.shift_right(shade, 16), FULL_COLOR].min

          # WHAT THE DARKEST LIGHT ADDS TO A CORNER'S COLOUR, with sixteen bits of fraction, for a shading of
          # +levels+ levels: one level's worth of FULL_COLOR. The interpreter shows light 0 at the shading's
          # level nought, and a shading that darkens evenly makes level nought one level's worth bright, not
          # black; level n is n + 1 levels' worth. So the colour at a light is FULL_COLOR times the light and
          # one level more, which is the shading's brightness where each level starts, and the texel as it
          # is from the last level on.
          def light_floor(levels) = Int32.div(FULL_COLOR << 16, levels)

          # Twice the area of a triangle of corners [x, y, ...], signed.
          def doubled_signed_area(triangle)
            (a, b, c) = triangle
            Int32.sub(Int32.mul(Int32.sub(b[0], a[0]), Int32.sub(c[1], a[1])), Int32.mul(Int32.sub(c[0], a[0]), Int32.sub(b[1], a[1])))
          end
        end
      end
    end
  end
end
