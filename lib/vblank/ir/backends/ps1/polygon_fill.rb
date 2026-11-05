# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE PLAYSTATION GRAPHICS CHIP FILLING A TEXTURED TRIANGLE, by its own rules, written in Ruby so
        # the checked run can say which pixels the chip draws for the triangles a program sends, and
        # which texel each shows. PS1::CheckedRun draws a place's faces this way on the interpreter's
        # side, and compares that with what the chip drew in the emulator: every pixel, with none let
        # off. It is the answer key for the chip, as the interpreter is for everything else, and no
        # build uses it.
        #
        # The rules are Beetle PSX's software rasteriser (mednafen/psx/gpu_polygon.c and gpu_uv_phase.h,
        # at the revision ruby-ps1-emulator builds), for the one kind of triangle the runtime sends: a raw
        # textured triangle (GP0 25h), opaque, at the console's own resolution, with no PGXP and no line
        # hack (the emulator's options at their defaults). psx-spx, "GPU Render Polygon Commands", says
        # the same of the hardware. It is a port line for line, so its local names are Beetle's
        # (cvtemp, vo, vp, lc, rc...), to be read beside the C.
        #
        # - THE CORNERS are whole pixels. They are sorted top to bottom, and the "core" corner (where the
        #   place on the picture is worked out from) is picked from their order before sorting
        #   (DrawTriangle's cvtemp).
        # - THE PLACE ON THE PICTURE steps across the triangle by two slopes a pixel, each a cross product
        #   over twice the area with 12 bits of fraction, cut toward nought, then moved up 12 more
        #   (CalcIDeltas, gpu_uv_delta). It starts at the core corner's texel plus HALF A TEXEL
        #   (gpu_uv_seed), and a pixel samples at its top-left corner: the place there is the seed stepped
        #   by how far across and down the pixel is from the core corner, in 32 bits that wrap, and its
        #   top eight bits are the texel.
        # - THE EDGES are walked a row at a time in 32.32 fixed point, from each edge's top corner plus a
        #   hair under one pixel (MakePolyXFP), stepping by the edge's slope rounded away from nought
        #   (MakePolyXFPStep). A row runs from the left edge's whole part to the right edge's, the right
        #   one left out.
        # - THE DRAWING AREA (GP0 E3h, E4h) holds every pixel inside it, its right and bottom included.
        # - A TEXEL OF 0000h is left undrawn (the caller's to leave out).
        # - A SHADED TRIANGLE (GP0 34h, a lit face's) carries a colour at each corner. It steps across the
        #   triangle by the same sums as the place on the picture (CalcIDeltas' dr_dx, with the C
        #   division), from the core corner's colour plus half a step (ig.r), and a pixel's colour is the
        #   top eight bits. The chip multiplies each texel's red, green and blue by it, 80h being the texel
        #   as it is (#self.modulated, ModTexel with dithering off).
        # - ONE OF THE EMULATOR'S OWN CORRECTIONS applies to these triangles too: a triangle one pixel tall
        #   whose place down the picture does not change across has its corners' v moved by one
        #   (Calc_UVOffsets_Adjust_Verts, "Wild Arms 2"), so it is modelled.
        #
        # Every corner the runtime sends lies on the screen, so the chip's 11-bit corners and its
        # 1023 × 511 limit never come into it and are not modelled.
        class PolygonFill
          # The fraction bits of a slope (COORD_FBS) and how far it is moved up besides
          # (COORD_POST_PADDING).
          SLOPE_FRACTION_BITS = 12
          SLOPE_PADDING_BITS = 12
          WORD_MASK = (1 << 32) - 1
          LONG_MASK = (1 << 64) - 1

          # Half a texel at the slopes' scale: the seed the chip starts a place on the picture from.
          HALF_TEXEL = 1 << (SLOPE_FRACTION_BITS - 1)

          # A corner as the chip holds it: whole pixels and whole texels, and the colour of a shaded
          # triangle's corner, nil for one not shaded (tri_vertex; red, green and blue alike).
          Vertex = Struct.new(:x, :y, :u, :v, :c)
          # How far u and v, and a shaded triangle's colour, move a pixel across and a row down (i_deltas),
          # each a word; the colour's nought on a triangle not shaded.
          Slopes = Data.define(:du_dx, :du_dy, :dv_dx, :dv_dy, :dc_dx, :dc_dy)
          # One of a triangle's two halves as the edges are walked (tripart): its first row and the row it
          # stops at, its left and right edges' places and steps, and whether it is walked upward.
          Half = Struct.new(:y_coord, :y_bound, :x_coord, :x_step, :upward)

          # The 15-bit +color+ a shaded triangle draws for a texel of that colour at colour +c+: each of red,
          # green and blue times c, over 80h, held to 1Fh (ModTexel: the channel times c moved down four
          # bits, then three in the dither table, whose undithered cell adds nought, held to 1Fh).
          def self.modulated(color, c)
            [0, 5, 10].sum { |shift| [((color >> shift) & 0x1F) * c >> 7, 0x1F].min << shift } | (color & 0x8000)
          end

          # +texel_seed+ is what is added to the core corner's texel before stepping; a test hands another
          # to show the check goes red on a wrong rule.
          def initialize(texel_seed: HALF_TEXEL)
            @texel_seed = texel_seed
          end

          # The pixels the chip draws for a triangle of +corners+ ([x, y, u, v] each, as sent, and a fifth,
          # the colour, for a shaded triangle), held to +area+ ([left, top, right, bottom], the last two
          # included). Yields each pixel's x, y, the texel the chip reads there (u, v, each 0 to 255) and
          # the colour it multiplies it by (nil for a triangle not shaded), in the order the chip draws them.
          def fill(corners, area, &)
            vertices = corners.map { |x, y, u, v, c| Vertex.new(x, y, u, v, c) }
            adjust_one_pixel_tall!(vertices)
            draw_triangle(vertices, area, &)
          end

          private

          def s32(n) = ((n + (1 << 31)) & WORD_MASK) - (1 << 31)
          def s64(n) = ((n + (1 << 63)) & LONG_MASK) - (1 << 63)

          # C's division of two ints: toward nought.
          def c_div(a, b)
            q = a.abs / b.abs
            a.negative? ^ b.negative? ? -q : q
          end

          # Calc_UVOffsets_Adjust_Verts, for a triangle at the console's resolution with no PGXP: only its
          # Wild Arms 2 correction moves anything.
          def adjust_one_pixel_tall!(v)
            abx = v[1].x - v[0].x
            aby = v[1].y - v[0].y
            bcx = v[2].x - v[1].x
            bcy = v[2].y - v[1].y
            cax = v[0].x - v[2].x
            cay = v[0].y - v[2].y
            dvdx = (-aby * v[2].v) - (bcy * v[0].v) - (cay * v[1].v)
            dvdy = (abx * v[2].v) + (bcx * v[0].v) + (cax * v[1].v)
            area = (bcx * cay) - (bcy * cax)
            tex_area = ((v[1].u - v[0].u) * (v[2].v - v[0].v)) - ((v[2].u - v[0].u) * (v[1].v - v[0].v))
            return if area.zero? || tex_area.zero?

            neg_dvdy = dvdy.negative? != area.negative?
            dys = [aby, bcy, cay]
            return unless dvdx.zero? && dys.include?(1) && dys.include?(0) && dys.include?(-1) && neg_dvdy

            if aby == -1 then v[0].v = v[1].v - 1
            elsif bcy == -1 then v[1].v = v[2].v - 1
            elsif cay == -1 then v[2].v = v[0].v - 1
            end
            if aby == 1 then v[1].v = v[0].v - 1
            elsif bcy == 1 then v[2].v = v[1].v - 1
            elsif cay == 1 then v[0].v = v[2].v - 1
            end
          end

          # DrawTriangle, for a raw textured triangle.
          def draw_triangle(v, area, &each_pixel)
            v = v.map(&:dup)
            cvtemp = if v[1].x <= v[0].x
                       v[2].x <= v[1].x ? 4 : 2
                     elsif v[2].x < v[0].x
                       4
                     else
                       1
                     end
            if v[2].y < v[1].y
              v[2], v[1] = v[1], v[2]
              cvtemp = ((cvtemp >> 1) & 2) | ((cvtemp << 1) & 4) | (cvtemp & 1)
            end
            if v[1].y < v[0].y
              v[1], v[0] = v[0], v[1]
              cvtemp = ((cvtemp >> 1) & 1) | ((cvtemp << 1) & 2) | (cvtemp & 4)
            end
            if v[2].y < v[1].y
              v[2], v[1] = v[1], v[2]
              cvtemp = ((cvtemp >> 1) & 2) | ((cvtemp << 1) & 4) | (cvtemp & 1)
            end
            core_vertex = cvtemp >> 1
            return if v[0].y == v[2].y

            slopes = texture_slopes(v[0], v[1], v[2])
            return unless slopes

            core = v[core_vertex]
            seed_u = ((core.u << SLOPE_FRACTION_BITS) + @texel_seed) << SLOPE_PADDING_BITS
            seed_v = ((core.v << SLOPE_FRACTION_BITS) + @texel_seed) << SLOPE_PADDING_BITS
            seed_u = (seed_u + (slopes.du_dx * -core.x) + (slopes.du_dy * -core.y)) & WORD_MASK
            seed_v = (seed_v + (slopes.dv_dx * -core.x) + (slopes.dv_dy * -core.y)) & WORD_MASK
            # The colour starts at the core corner's plus half a step, always (ig.r).
            seed_c = ((((core.c || 0) << SLOPE_FRACTION_BITS) + HALF_TEXEL) << SLOPE_PADDING_BITS)
            seed_c = (seed_c + (slopes.dc_dx * -core.x) + (slopes.dc_dy * -core.y)) & WORD_MASK
            seeds = [seed_u, seed_v, (seed_c unless core.c.nil?)]
            halves(v, core_vertex).each do |half|
              walk_half(half, area) { |y, x_start, x_bound| draw_span(y, x_start, x_bound, seeds, slopes, area, &each_pixel) }
            end
          end

          # DrawTriangle's two tripart halves, in the order it walks them.
          def halves(v, core_vertex)
            base_coord = poly_xfp(v[0].x)
            base_step = poly_xfp_step(v[2].x - v[0].x, v[2].y - v[0].y)
            if v[1].y == v[0].y
              bound_coord_us = 0
              right_facing = v[1].x > v[0].x
            else
              bound_coord_us = poly_xfp_step(v[1].x - v[0].x, v[1].y - v[0].y)
              right_facing = bound_coord_us > base_step
            end
            bound_coord_ls = v[2].y == v[1].y ? 0 : poly_xfp_step(v[2].x - v[1].x, v[2].y - v[1].y)
            vo = core_vertex.zero? ? 0 : 1
            vp = core_vertex == 2 ? 3 : 0
            rf = right_facing ? 1 : 0
            halves = Array.new(2) { Half.new(x_coord: [0, 0], x_step: [0, 0]) }
            first = halves[vo]
            first.y_coord = v[0 ^ vo].y
            first.y_bound = v[1 ^ vo].y
            first.x_coord[rf] = poly_xfp(v[0 ^ vo].x)
            first.x_step[rf] = bound_coord_us
            first.x_coord[1 - rf] = s64(base_coord + ((v[vo].y - v[0].y) * base_step))
            first.x_step[1 - rf] = base_step
            first.upward = vo != 0
            second = halves[vo ^ 1]
            second.y_coord = v[1 ^ vp].y
            second.y_bound = v[2 ^ vp].y
            second.x_coord[rf] = poly_xfp(v[1 ^ vp].x)
            second.x_step[rf] = bound_coord_ls
            second.x_coord[1 - rf] = s64(base_coord + ((v[1 ^ vp].y - v[0].y) * base_step))
            second.x_step[1 - rf] = base_step
            second.upward = vp != 0
            halves
          end

          # The rows of one half inside the drawing area, each yielded with where its pixels start and the
          # pixel past where they stop.
          def walk_half(half, area)
            _, top, _, bottom = area
            yi = half.y_coord
            yb = half.y_bound
            lc, rc = half.x_coord
            ls, rs = half.x_step
            if half.upward
              while yi > yb
                yi -= 1
                lc = s64(lc - ls)
                rc = s64(rc - rs)
                break if yi < top
                next if yi > bottom

                yield yi, lc >> 32, rc >> 32
              end
            else
              while yi < yb
                break if yi > bottom

                yield yi, lc >> 32, rc >> 32 if yi >= top
                yi += 1
                lc = s64(lc + ls)
                rc = s64(rc + rs)
              end
            end
          end

          # DrawSpan: the pixels of row +y+ from +x_start+ up to +x_bound+, held to the drawing area. +seeds+
          # are u's, v's and the colour's (nil for a triangle not shaded).
          def draw_span(y, x_start, x_bound, seeds, slopes, area)
            seed_u, seed_v, seed_c = seeds
            left, _, right, = area
            x = x_start
            width = x_bound - x_start
            if x < left
              width -= left - x
              x = left
            end
            width = right + 1 - x if x + width > right + 1
            return if width <= 0

            u = (seed_u + (slopes.du_dx * x) + (slopes.du_dy * y)) & WORD_MASK
            v = (seed_v + (slopes.dv_dx * x) + (slopes.dv_dy * y)) & WORD_MASK
            c = seed_c && ((seed_c + (slopes.dc_dx * x) + (slopes.dc_dy * y)) & WORD_MASK)
            whole = SLOPE_FRACTION_BITS + SLOPE_PADDING_BITS
            width.times do
              yield x, y, u >> whole, v >> whole, c && (c >> whole)
              x += 1
              u = (u + slopes.du_dx) & WORD_MASK
              v = (v + slopes.dv_dx) & WORD_MASK
              c = (c + slopes.dc_dx) & WORD_MASK if c
            end
          end

          # CalcIDeltas for u and v, and for a shaded triangle its colour (the same sums), or nil for a
          # triangle with no area.
          def texture_slopes(a, b, c)
            cross = ->(p, q) { s32(s32(((b[p] || 0) - (a[p] || 0)) * ((c[q] || 0) - (b[q] || 0))) - s32(((c[p] || 0) - (b[p] || 0)) * ((b[q] || 0) - (a[q] || 0)))) }
            denom = cross.call(:x, :y)
            return nil if denom.zero?

            delta = ->(cis) { (s32(c_div(s32(cis * (1 << SLOPE_FRACTION_BITS)), denom)) << SLOPE_PADDING_BITS) & WORD_MASK }
            Slopes.new(du_dx: delta.call(cross.call(:u, :y)), du_dy: delta.call(cross.call(:x, :u)),
                       dv_dx: delta.call(cross.call(:v, :y)), dv_dy: delta.call(cross.call(:x, :v)),
                       dc_dx: delta.call(cross.call(:c, :y)), dc_dy: delta.call(cross.call(:x, :c)))
          end

          # MakePolyXFP: a corner's x as 32.32, a hair under one pixel on.
          def poly_xfp(x) = s64((x << 32) + ((1 << 32) - (1 << 11)))

          # MakePolyXFPStep: how far an edge moves across a row, as 32.32, rounded away from nought.
          def poly_xfp_step(dx, dy)
            ex = dx << 32
            ex -= dy - 1 if ex.negative?
            ex += dy - 1 if ex.positive?
            c_div(ex, dy)
          end
        end
      end
    end
  end
end
