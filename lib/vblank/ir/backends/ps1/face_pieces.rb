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
        #    screen. The chip's drawing area is set to the same edges, so its pixels stop there too.
        # 2. IN PERSPECTIVE, CUT INTO SQUARES of the screen, along every 32nd row and column (every 8th
        #    for `perspective: :every_pixel`): each new corner's place on the picture is worked out
        #    exactly (the place over the distance, times the distance, as Reference#place_in_perspective
        #    does), and the chip steps straight between. That is how the console's own games drew a near
        #    wall. A screen covered by one face is then about 75 squares, or about 1200 at every pixel,
        #    each a cut or two and a few triangles; squares of 16 would be four times the work.
        # 3. CUT WHERE THE PICTURE WOULD RUN PAST A BYTE: a piece whose place on the picture spans more
        #    than 256 is cut at 256 past its least, as often as it takes. The picture repeats by the
        #    chip's texture window (GP0 E2h), so each piece's places are moved by whole pictures to
        #    start between 0 and the picture's size.
        # 4. SENT as a fan of triangles from the piece's first corner, each corner rounded to the
        #    nearest whole pixel; a triangle with no area is left out (the chip draws nothing of one).
        #
        # A corner is NUMBERS numbers, by these places: X and Y, in sixteenths of a pixel; U_SOURCE,
        # V_SOURCE and NEARNESS, what the place on the picture is worked out from (without perspective
        # u and v themselves, with sixteen fraction bits, and no nearness; in perspective u and v over
        # the distance and one over the distance, as Reference::FaceEdges.in_perspective has them); and
        # TEXEL_U, TEXEL_V, the whole texel the corner sends. Every sum is IR::Int32's, so it wraps where
        # the processor's does.
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
          NUMBERS = 7

          # The most corners a piece keeps: a face's eight, one more for each of the four clipping
          # edges, the two lines of a square it is cut by each way and a cut each way on the picture,
          # with room over. A face that is not flat can cross a line more often than a flat one; past
          # this many, a piece keeps its first ones.
          MOST_CORNERS = 24

          # The side of a square a face in perspective is cut into: EVERY_PIXEL_CELL_PIXELS for a face whose
          # place on the picture the interpreter works out at every pixel (a perspective of 1), and
          # CELL_PIXELS for any other perspective (every eight pixels, or a number the game works out).
          CELL_PIXELS = 32
          EVERY_PIXEL_CELL_PIXELS = 8

          # The bits of fraction in the share of an edge a cut is along.
          SHARE_BITS = 14

          # How many pieces can wait to be cut on the picture at once. Past this, a further one is left
          # out, as the runtime's room for them is.
          MOST_WAITING = 8

          # How far a piece's place on the picture may run: a byte's worth past its least.
          PICTURE_REACH = 256

          # One triangle as the chip is sent it: three corners [x, y, u, v], x and y whole pixels on the
          # screen, u and v the texel in the picture's page.
          Triangle = Data.define(:corners)

          module_function

          # The triangles one face is sent as, in the order they are sent: +corners+ the face's corners as
          # the list holds them ([x, y, u, v, w, light] each), +edges+ [left, top, right, bottom] already
          # held to the screen and the area drawing is held to, +spans+ the face's perspective, and the
          # picture's +width+ and +height+.
          def triangles(corners:, edges:, spans:, width:, height:)
            left, top, right, bottom = edges
            return [] if left >= right || top >= bottom

            face = corners.map { |corner| corner_from_list(*corner.first(5), spans) }
            face = keep_side(face, X, Int32.mul(left, 16), :above, spans)
            face = keep_side(face, X, Int32.mul(right, 16), :below, spans)
            face = keep_side(face, Y, Int32.mul(top, 16), :above, spans)
            face = keep_side(face, Y, Int32.mul(bottom, 16), :below, spans)
            return [] if face.length < 3

            sent = []
            each_cell(face, spans) { |piece| send_cut_on_picture(piece, width, height, sent) }
            sent
          end

          # The corner a face's corner becomes (see the module's note).
          def corner_from_list(x, y, u, v, w, spans)
            corner = if spans == Nodes::FillFace::PERSPECTIVE_NONE
                       [x, y, u, v, 0, 0, 0]
                     else
                       [x, y, Int32.mul_fix(u, w, 28), Int32.mul_fix(v, w, 28), w, 0, 0]
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
          # in both. +spans+ says how a corner made on a screen line has its texel worked out.
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
          def corner_between(from, to, from_side, to_side, number, line, spans)
            start, finish, start_side, finish_side = from_side.negative? ? [from, to, from_side, to_side] : [to, from, to_side, from_side]
            share = Int32.div(Int32.shift_left(Int32.sub(0, start_side), SHARE_BITS), Int32.sub(finish_side, start_side))
            made = Array.new(NUMBERS) do |part|
              Int32.add(start[part], Int32.mul_fix(Int32.sub(finish[part], start[part]), share, SHARE_BITS))
            end
            made[number] = line
            [X, Y].include?(number) ? set_texel!(made, spans) : made
          end

          # Each piece of +face+ in turn: the face itself without perspective; in perspective, the face cut
          # along every CELL_PIXELS-th row of the screen it crosses, top down, and each strip along every
          # CELL_PIXELS-th column, left to right.
          def each_cell(face, spans, &block)
            return yield(face) if spans == Nodes::FillFace::PERSPECTIVE_NONE

            side = Int32.mul(spans == 1 ? EVERY_PIXEL_CELL_PIXELS : CELL_PIXELS, 16)
            each_strip(face, Y, side, spans) { |strip| each_strip(strip, X, side, spans, &block) }
          end

          # +piece+ cut along every line of +number+ a multiple of +side+ strictly inside it, the part
          # before each line in turn, then the rest. A part of fewer than three corners is left out.
          def each_strip(piece, number, side, spans)
            least, most = piece.map { |corner| corner[number] }.minmax
            line = Int32.add(Int32.bit_and(least, Int32.sub(0, side)), side)
            rest = piece
            while line < most
              part, rest = cut(rest, number, line, spans)
              yield part if part.length >= 3
              line = Int32.add(line, side)
            end
            yield rest if rest.length >= 3
          end

          # +piece+ cut on the picture until each part's places run no more than PICTURE_REACH across and
          # down, and each part sent (see the module's note). The part past a cut waits while the part
          # before it is finished.
          def send_cut_on_picture(piece, width, height, sent)
            waiting = [piece]
            until waiting.empty?
              part = waiting.pop
              while part.length >= 3
                number, line = find_picture_cut(part, width, height)
                unless number
                  send_fan(part, width, height, sent)
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
          # start between nought and the picture's size, each held to a byte.
          def send_fan(piece, width, height, sent)
            u_base = Int32.bit_and(piece.map { |corner| corner[TEXEL_U] }.min, Int32.sub(0, width))
            v_base = Int32.bit_and(piece.map { |corner| corner[TEXEL_V] }.min, Int32.sub(0, height))
            sent_corners = piece.map do |corner|
              [Int32.shift_right(Int32.add(corner[X], 8), 4), Int32.shift_right(Int32.add(corner[Y], 8), 4),
               [Int32.sub(corner[TEXEL_U], u_base), 255].min, [Int32.sub(corner[TEXEL_V], v_base), 255].min]
            end
            (1...(sent_corners.length - 1)).each do |at|
              triangle = [sent_corners[0], sent_corners[at], sent_corners[at + 1]]
              sent << Triangle.new(corners: triangle) unless doubled_signed_area(triangle).zero?
            end
          end

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
