# frozen_string_literal: true

module VBlank
  module IR
    # HOW A PLACE MADE OF FLAT FACES IS DRAWN, written once as statements every target runs
    # (see Nodes::DrawPlace). A place is points in space and faces that join three or four of
    # them, and drawing it as a viewer sees it is, for each face:
    #
    #   - TURN each corner's point to the viewer. Take the viewer's spot away from the point, and
    #     measure what is left along the viewer's three arrows (right, up and ahead). That gives
    #     how far the point is to the viewer's right, above them and in front of them.
    #   - CUT the face at the near limit. A corner nearer than that is left out, and where an
    #     edge crosses the limit a new corner is made on it, so a face beside the viewer is drawn
    #     as far as the limit rather than not at all. A face of four corners comes out with up to
    #     five (eight at most, which is the corner list's room).
    #   - PROJECT each corner onto the screen. A point twice as far ahead looks half as far from
    #     the middle of the view, so how far right it lands is how far right it is divided by how
    #     far ahead it is, made bigger by how wide an angle the view shows.
    #   - SKIP the face when it is seen from behind (unless the place is drawn from both sides):
    #     its corners then go round the other way on the screen.
    #   - FILL it with its picture (Nodes::FillFace).
    #
    # A game that works out for itself which faces it can see (a game of rooms, seeing the next
    # room only through a doorway) hands the drawing a list of faces and a window to hold them to,
    # and asks where a doorway's corners land through the spot routine: the same turn and the same
    # projection as a corner's, so the window it builds fits the faces drawn to the pixel.
    #
    # WHY THESE ARE STATEMENTS AND NOT A ROUTINE OF EACH TARGET'S OWN. Every target that works
    # the sums out itself runs these same statements, so every one of them turns, cuts and
    # projects each point to the same bits, and only the fill is written again for each. Every
    # number is a fraction with sixteen bits, as a game's fractions are, and every product and
    # quotient goes through Int32.mul_fix and Int32.div_fix, where the rounding is settled.
    #
    # WHY NOTHING OVERFLOWS. A point and the viewer each stay within FURTHEST of the middle of
    # the place, so a point is at most twice that from the viewer along each of the three
    # arrows, and how far it is along any one arrow is never more than its whole distance,
    # under the most a fraction holds. A corner can still land far off the screen, so where one
    # lands is held to LANDING_LIMIT pixels either side of the screen's corner, which keeps the
    # fill's sums inside a number: a face reaching past that is drawn bent.
    class PlaceDrawing
      # A place's faces table keeps, for each face, the number of its picture slot and then,
      # for each of its four corners, the number of its point and where it falls on the
      # picture (u, v). A face of three corners gives its third twice.
      FACE_SLOT = 0
      CORNERS = 4
      CORNER_FIELDS = 3
      FACE_STRIDE = 1 + (CORNERS * CORNER_FIELDS)
      # ...and its points table three numbers a point: x, y, z.
      POINT_STRIDE = 3

      # How far a point or the viewer may be from the middle of the place, either way, along
      # each of the three arrows (see WHY NOTHING OVERFLOWS).
      FURTHEST = 8_191

      # How much finer than a pixel a corner's place on the screen is kept: sixteenths.
      SUBPIXEL = 16
      LANDING_LIMIT = 2048 * SUBPIXEL

      # The viewer's twelve numbers, in the order a viewer keeps them: its spot, then its right,
      # up and ahead arrows.
      VIEWER_PARTS = %i[x y z right_x right_y right_z up_x up_y up_z ahead_x ahead_y ahead_z].freeze

      # What the routine is told about the view before each drawing (see View).
      VIEW_PARTS = %i[left top right bottom middle_x middle_y focal near both_sides].freeze

      # The edges a face is held to, in the order a window gives them.
      CLIP_EDGES = %i[left top right bottom].freeze

      # WHAT THE ROUTINE IS TOLD ABOUT THE VIEW: its edges in whole pixels, its middle in
      # sixteenths of one, how far a point one whole to the side at one whole ahead lands from the
      # middle (+focal+, sixteenths), the near limit (a fraction with sixteen bits), and 1 when
      # a face is drawn from behind as well.
      View = Data.define(*VIEW_PARTS) do
        # The view over the screen area +left+, +top+, +width+, +height+, +degrees+ across.
        def self.over(left, top, width, height, degrees:, near:, both_sides:)
          focal = ((width / 2.0) / Math.tan(degrees * Math::PI / 360) * SUBPIXEL).round
          new(left: left, top: top, right: left + width, bottom: top + height,
              middle_x: ((left * 2) + width) * SUBPIXEL / 2, middle_y: ((top * 2) + height) * SUBPIXEL / 2,
              focal: focal, near: near, both_sides: both_sides ? 1 : 0)
        end
      end

      # The name of +part+ of place +place+ (a table, a list, a variable or a routine).
      def self.name_of(place, part) = Messages::MadeNames.make(:place_part, place: place, part: part)

      # +place+ is the place's name, +faces+ and +points+ how many it has, and +pictures+ the
      # pictures it can show, in order: a face's slot holds how far its picture is along these
      # from the slot's own.
      def initialize(place, faces:, points:, pictures:)
        @place = place
        @faces = faces
        @points = points
        @pictures = pictures
      end

      def routine = name(:draw)
      def face_routine = name(:face_drawing)
      def corner_routine = name(:corner)
      def point_routine = name(:point_turning)
      def spot_routine = name(:spot)
      def points_table = name(:points)
      def faces_table = name(:faces)
      def slots_list = name(:slots)
      def corners_list = name(:corners)
      def seen_list = name(:seen)
      def stamps_list = name(:stamps)

      # WHAT A DRAWING KEEPS OF EACH POINT IT HAS MET, so that the faces sharing a point turn it
      # once between them, not once each. A point of a closed shape is a corner of three faces or
      # more, and turning it is most of what a face costs before it is filled.
      #
      # The seen list keeps, for each point, SEEN_STRIDE numbers: where it is to the viewer's right,
      # above and ahead, and where it lands on the screen across and down (written only when it is
      # in front of the near limit, the only time anything reads them). The stamps list keeps, for
      # each point, the number of the drawing that last turned it: every drawing counts one on
      # (the drawing variable), so a point whose stamp is not the drawing's own is turned afresh.
      # Both start full of nought and the count starts at one, so nothing is read before it is
      # written; the count is not part of the game's state that `start_over` puts back, and the
      # lists are, which only ever makes a stamp stale.
      SEEN_STRIDE = 5
      SEEN_ACROSS = 3
      SEEN_DOWN = 4

      # The variable the routine reads the viewer's +part+ from.
      def viewer_var(part) = name(:"viewer_#{part}")

      # The variable the routine reads the view's +part+ from.
      def view_var(part) = name(:"view_#{part}")

      # The variables holding the rectangle a face is held to: +edge+ is left, top, right or
      # bottom. The view's own edges, unless the game gave a window.
      def clip_var(edge) = name(:"clip_#{edge}")

      # The variables the spot routine reads its point from and leaves its answers in.
      def spot_point_var = name(:spot_point)
      def spot_answer_var(part) = name(:"spot_#{part}")

      # Every variable the routines keep their work in, the viewer's and the view's included.
      def variables
        VIEWER_PARTS.map { |part| viewer_var(part) } + VIEW_PARTS.map { |part| view_var(part) } +
          CLIP_EDGES.map { |edge| clip_var(edge) } +
          %i[face listed base slot picture point seen_point dx dy dz count along area each next drawing
             at_x at_y at_z at_u at_v spot_point spot_x spot_y spot_behind].map { |part| name(part) } +
          CORNERS.times.flat_map { |k| %i[p x y z u v].map { |field| turned_var(field, k) } }
      end

      # The variable counting the drawings, which marks the points each has turned (see SEEN_STRIDE).
      def drawing_var = name(:drawing)

      # The drawing routine's statements: every face, in the order the place declares them.
      def statements
        [Build.repeat(@faces, name(:face), Build.call(face_routine))]
      end

      # The faces whose numbers list +list+ holds, in its order, drawn where the game says; a
      # number that is not one of the place's faces is passed over. The list's length is read
      # once, as the drawing starts.
      def listed_statements(list)
        face = var(:face)
        known = Build.binop(:and, Build.binop(:>=, face, 0), Build.binop(:<, face, @faces))
        [Build.repeat(Build.list_len(list), name(:listed),
                      Build.set(name(:face), Build.list_get(list, var(:listed))),
                      Build.if_(known, Build.call(face_routine)))]
      end

      # One face's statements, the face whose number is in the face variable: turned, cut,
      # projected, tested and filled.
      def face_statements
        [Build.set(name(:base), Build.binop(:*, var(:face), FACE_STRIDE)),
         Build.set(name(:slot), Build.table_get(faces_table, face_field(FACE_SLOT))),
         Build.set(name(:picture), Build.binop(:+, var(:slot), Build.list_get(slots_list, var(:slot)))),
         *CORNERS.times.flat_map { |k| turned_corner(k) },
         Build.set(name(:count), 0),
         *CORNERS.times.flat_map { |k| cut_edge(k) },
         Build.if_(Build.binop(:>=, var(:count), 3), *front_test, fill_when_seen)]
      end

      # Where the point whose number is in the spot's point variable lands, turned and projected
      # as a face's corner is: the pixel whose middle is first at or past it, across and down, and
      # whether it is nearer than the near limit (then both are nought).
      def spot_statements
        point = Build.binop(:*, Build.clamped(Build.var_ref(spot_point_var), 0, @points - 1), POINT_STRIDE)
        pixel = ->(sixteenths) { Build.shift_right(Build.binop(:+, sixteenths, (SUBPIXEL / 2) - 1), 4) }
        [Build.set(name(:point), point),
         *offsets_from_viewer,
         Build.set(name(:at_x), along(:right)),
         Build.set(name(:at_y), along(:up)),
         Build.set(name(:at_z), along(:ahead)),
         Build.set(spot_answer_var(:x), 0),
         Build.set(spot_answer_var(:y), 0),
         Build.set(spot_answer_var(:behind), 1),
         Build.if_(Build.binop(:>=, var(:at_z), Build.var_ref(view_var(:near))),
                   Build.set(spot_answer_var(:x), pixel.call(landed(:+, :at_x, :middle_x))),
                   Build.set(spot_answer_var(:y), pixel.call(landed(:-, :at_y, :middle_y))),
                   Build.set(spot_answer_var(:behind), 0))]
      end

      # The point routine: the point whose number is in the seen-point variable turned to the
      # viewer, put on the screen when it is in front of the near limit, both kept in the seen list,
      # and the point stamped as seen by this drawing (see SEEN_STRIDE).
      def point_statements
        number = var(:seen_point)
        seen = Build.binop(:*, number, SEEN_STRIDE)
        [Build.set(name(:point), Build.binop(:*, number, POINT_STRIDE)),
         *offsets_from_viewer,
         Build.set(name(:at_x), along(:right)),
         Build.set(name(:at_y), along(:up)),
         Build.set(name(:at_z), along(:ahead)),
         *%i[at_x at_y at_z].each_with_index.map { |part, at| Build.list_set(seen_list, Build.binop(:+, seen, at), var(part)) },
         Build.if_(Build.binop(:>=, var(:at_z), Build.var_ref(view_var(:near))),
                   Build.list_set(seen_list, Build.binop(:+, seen, SEEN_ACROSS), landed(:+, :at_x, :middle_x)),
                   Build.list_set(seen_list, Build.binop(:+, seen, SEEN_DOWN), landed(:-, :at_y, :middle_y))),
         Build.list_set(stamps_list, number, var(:drawing))]
      end

      # The corner routine: the corner in at_x, at_y, at_z (turned, at_z at or past the near
      # limit), at_u and at_v put on the screen and added to the corner list.
      def corner_statements
        at = var(:count)
        place = ->(offset) { Build.binop(:+, Build.binop(:*, at, Nodes::FillFace::CORNER_NUMBERS), offset) }
        [Build.list_set(corners_list, place.call(0), landed(:+, :at_x, :middle_x)),
         Build.list_set(corners_list, place.call(1), landed(:-, :at_y, :middle_y)),
         Build.list_set(corners_list, place.call(2), var(:at_u)),
         Build.list_set(corners_list, place.call(3), var(:at_v)),
         Build.add(name(:count), 1)]
      end

      private

      def name(part) = self.class.name_of(@place, part)

      def var(part) = Build.var_ref(name(part))

      def turned_var(field, k) = name(:"#{field}#{k}")

      def turned(field, k) = Build.var_ref(turned_var(field, k))

      # The faces table's entry +offset+ along the face being drawn.
      def face_field(offset) = Build.binop(:+, var(:base), offset)

      # Corner +k+ of the face being drawn, turned to the viewer, with where it falls on the
      # picture. Its point is turned (and put on the screen, when it is in front of the near limit)
      # only the first time this drawing meets it; every face after that sharing the point reads
      # what the first worked out (see SEEN_STRIDE).
      def turned_corner(k)
        first = 1 + (k * CORNER_FIELDS)
        number = turned(:p, k)
        seen = Build.binop(:*, number, SEEN_STRIDE)
        [Build.set(turned_var(:p, k), Build.table_get(faces_table, face_field(first))),
         Build.if_(Build.binop(:!=, Build.list_get(stamps_list, number), var(:drawing)),
                   Build.set(name(:seen_point), number),
                   Build.call(point_routine)),
         *%i[x y z].each_with_index.map { |field, at| Build.set(turned_var(field, k), Build.list_get(seen_list, Build.binop(:+, seen, at))) },
         Build.set(turned_var(:u, k), Build.table_get(faces_table, face_field(first + 1))),
         Build.set(turned_var(:v, k), Build.table_get(faces_table, face_field(first + 2)))]
      end

      # The offset of the point whose place in the points table is in the point variable from the
      # viewer's spot, along x, y and z, into dx, dy and dz.
      def offsets_from_viewer
        %i[dx dy dz].each_with_index.map do |part, axis|
          at = Build.binop(:+, var(:point), axis)
          Build.set(name(part), Build.binop(:-, Build.table_get(points_table, at), Build.var_ref(viewer_var(VIEWER_PARTS[axis]))))
        end
      end

      # How far the point a corner names is along one of the viewer's arrows: its offset from the
      # viewer measured along the arrow, three products added.
      def along(arrow)
        %i[x y z].map do |axis|
          Build.mul_fix(var(:"d#{axis}"), Build.var_ref(viewer_var(:"#{arrow}_#{axis}")), 16)
        end.reduce { |sum, product| Build.binop(:+, sum, product) }
      end

      def in_front(k) = Build.binop(:>=, turned(:z, k), Build.var_ref(view_var(:near)))

      # The edge from corner +k+ to the next, cut at the near limit: corner +k+ itself when it is
      # in front of the limit, and then, when the edge crosses the limit, the corner where it
      # does, worked out along the edge by how far through it the limit is.
      def cut_edge(k)
        other = (k + 1) % CORNERS
        through = Build.div_fix(Build.binop(:-, Build.var_ref(view_var(:near)), turned(:z, k)),
                                Build.binop(:-, turned(:z, other), turned(:z, k)), 16)
        moved = lambda do |field|
          Build.binop(:+, turned(field, k),
                      Build.mul_fix(Build.binop(:-, turned(field, other), turned(field, k)), var(:along), 16))
        end
        seen = Build.binop(:*, turned(:p, k), SEEN_STRIDE)
        corner = ->(offset) { Build.binop(:+, Build.binop(:*, var(:count), Nodes::FillFace::CORNER_NUMBERS), offset) }
        [Build.if_(in_front(k),
                   Build.list_set(corners_list, corner.call(0), Build.list_get(seen_list, Build.binop(:+, seen, SEEN_ACROSS))),
                   Build.list_set(corners_list, corner.call(1), Build.list_get(seen_list, Build.binop(:+, seen, SEEN_DOWN))),
                   Build.list_set(corners_list, corner.call(2), turned(:u, k)),
                   Build.list_set(corners_list, corner.call(3), turned(:v, k)),
                   Build.add(name(:count), 1)),
         Build.if_(Build.binop(:!=, in_front(k), in_front(other)),
                   Build.set(name(:along), through),
                   *%i[x y u v].map { |field| Build.set(name(:"at_#{field}"), moved.call(field)) },
                   Build.set(name(:at_z), Build.var_ref(view_var(:near))),
                   Build.call(corner_routine))]
      end

      # Where a corner lands on the screen, in sixteenths of a pixel: across from the middle by
      # how far right it is over how far ahead, and down from it by how far up (the screen's rows
      # count downward).
      def landed(op, offset, middle)
        ratio = Build.div_fix(var(offset), var(:at_z), 16)
        spot = Build.binop(op, Build.var_ref(view_var(middle)), Build.mul_fix(ratio, Build.var_ref(view_var(:focal)), 16))
        Build.clamped(spot, -LANDING_LIMIT, LANDING_LIMIT)
      end

      # Twice the area the corners on the screen go round, measured from the first corner: more
      # than nothing when they go round clockwise, as a face seen from in front does. Each
      # product is taken down eight bits, so it stays inside a number for any corner the
      # projection lets through.
      def front_test
        corner = ->(index, axis) { Build.list_get(corners_list, Build.binop(:+, Build.binop(:*, index, 4), axis)) }
        from_first = ->(index, axis) { Build.binop(:-, corner.call(index, axis), corner.call(0, axis)) }
        each = var(:each)
        following = var(:next)
        [Build.set(name(:area), 0),
         Build.repeat(var(:count), name(:each),
                      Build.set(name(:next), Build.binop(:+, each, 1)),
                      Build.if_(Build.binop(:==, following, var(:count)), Build.set(name(:next), 0)),
                      Build.set(name(:area),
                                Build.binop(:+, var(:area),
                                            Build.binop(:-, Build.mul_fix(from_first.call(each, 0), from_first.call(following, 1), 8),
                                                        Build.mul_fix(from_first.call(following, 0), from_first.call(each, 1), 8)))))]
      end

      # The fill, when the face is seen from in front or the place is drawn from both sides.
      def fill_when_seen
        edges = CLIP_EDGES.map { |edge| Build.var_ref(clip_var(edge)) }
        fill = Build.fill_face(@pictures, var(:picture), corners_list, var(:count), edges)
        seen = Build.binop(:or, Build.binop(:>, var(:area), 0), Build.binop(:==, Build.var_ref(view_var(:both_sides)), 1))
        Build.if_(seen, fill)
      end
    end
  end
end
