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
    #   - PASS OVER the face when the corners it was cut to lie wholly past one edge of its window
    #     (see OUTCODE_EDGES).
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
      # for each of its four corners, the number of its point, where it falls on the picture
      # (u, v) and its light. A face of three corners gives its third twice.
      FACE_SLOT = 0
      CORNERS = 4

      # What is kept of each corner once turned: its point, where it is, its place on the
      # picture and its light.
      TURNED_FIELDS = %i[p x y z u v light].freeze
      CORNER_FIELDS = 4
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
      VIEW_PARTS = %i[left top right bottom middle_x middle_y focal near both_sides perspective lit].freeze

      # The edges a face is held to, in the order a window gives them.
      CLIP_EDGES = %i[left top right bottom].freeze

      # WHAT THE ROUTINE IS TOLD ABOUT THE VIEW: its edges in whole pixels, its middle in
      # sixteenths of one, how far a point one whole to the side at one whole ahead lands from the
      # middle (+focal+, sixteenths), the near limit (a fraction with sixteen bits), 1 when a face
      # is drawn from behind as well, how far apart a row's pictures are put in perspective
      # (Nodes::FillFace::PERSPECTIVE_SPANS), and 1 when the place is drawn lit by its shading.
      View = Data.define(*VIEW_PARTS) do
        # The view over the screen area +left+, +top+, +width+, +height+, +degrees+ across.
        def self.over(left, top, width, height, degrees:, near:, both_sides:, perspective: :none, lit: false)
          focal = ((width / 2.0) / Math.tan(degrees * Math::PI / 360) * SUBPIXEL).round
          new(left: left, top: top, right: left + width, bottom: top + height,
              middle_x: ((left * 2) + width) * SUBPIXEL / 2, middle_y: ((top * 2) + height) * SUBPIXEL / 2,
              focal: focal, near: near, both_sides: both_sides ? 1 : 0,
              perspective: Nodes::FillFace::PERSPECTIVE_SPANS.fetch(perspective), lit: lit ? 1 : 0)
        end
      end

      # The name of +part+ of place +place+ (a table, a list, a variable or a routine).
      def self.name_of(place, part) = Messages::MadeNames.make(:place_part, place: place, part: part)

      # +place+ is the place's name, +faces+ and +points+ how many it has, and +pictures+ the
      # pictures it can show, in order: a face's slot holds how far its picture is along these
      # from the slot's own.
      #
      # +shading+ is the shading a lit drawing of the place fills its faces with (nil for a place
      # never lit), and +point_lights+ the list of light the game adds to each point as it runs
      # (nil for none). +corners_in_a_loop+ says a face's corners are worked in a loop rather than written
      # out four times (#face_loop_statements). +outcode_test+ says the drawing passes over a face wholly
      # outside its window itself (OUTCODE_EDGES); false where the target's fill does that already.
      def initialize(place, faces:, points:, pictures:, shading: nil, point_lights: nil, corners_in_a_loop: false,
                     outcode_test: true)
        @place = place
        @faces = faces
        @points = points
        @pictures = pictures
        @shading = shading
        @point_lights = point_lights
        @corners_in_a_loop = corners_in_a_loop
        @outcode_test = outcode_test
      end

      def routine = name(:draw)
      def face_routine = name(:face_drawing)
      def corner_routine = name(:corner)
      def point_routine = name(:point_turning)
      def spot_routine = name(:spot)
      def count_routine = name(:counting)
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
      # above and ahead, and where it lands on the screen across and down and one over how far ahead
      # it is (written only when it is in front of the near limit, the only time anything reads
      # them). One over how far ahead is worked out only for a drawing in perspective, the only one
      # that reads it. Where the corners are worked in a loop, a point turned for any other holds
      # nought there, which no point in front can have, and the first drawing in perspective to read it
      # works it out then (#nearness_filled); written out four times, whether the drawing is in
      # perspective is one of TURN_PARTS instead, which costs no test a corner. The stamps list keeps, for
      # each point, the number of the drawing that last turned it: a drawing counts one on (the
      # drawing variable) when it sees the place differently from the last (see TURN_PARTS), so a
      # point whose stamp is not the count is turned afresh.
      # Both start full of nought and the count starts at one, so nothing is read before it is
      # written; the count is not part of the game's state that `start_over` puts back, and the
      # lists are, which only ever makes a stamp stale.
      SEEN_STRIDE = 6
      SEEN_ACROSS = 3
      SEEN_DOWN = 4
      SEEN_NEARNESS = 5

      # WHAT A POINT'S TURN IS WORKED OUT FROM: the viewer, and the parts of the view the point routine
      # reads (the near limit, the view's middle and how wide it is). A drawing that sees the place from
      # the same viewer through the same view as the last one to move the count on turns every point
      # the same, so it does not move the count on, and the points that one turned are read again rather
      # than turned afresh. A game of rooms draws each room with a call of its own, its doorways' corners
      # shared with the rooms either side, and asks where they land (`screen_spot`) before it draws, so
      # most points are turned once a frame, not once for each room and once more for the asking.
      # The window is not among them: it holds where faces are filled, not where points land.
      #
      # THE NEAR LIMIT NEED NOT MATCH. Where a point lands does not depend on it; only whether the point
      # routine writes that down does (a point in front of the limit). So points turned with a nearer
      # limit than a drawing's hold everything that drawing reads, and only a drawing whose limit is
      # nearer than the one the points were turned with moves the count on for it. A game that asks
      # where points land with a limit of its own, nearer than its drawings', still turns each once.
      TURN_VIEW_PARTS = %i[near middle_x middle_y focal].freeze
      TURN_PARTS = [*VIEWER_PARTS, *TURN_VIEW_PARTS, :in_perspective].freeze

      MATCHED_TURN_PARTS = (TURN_PARTS - %i[near in_perspective]).freeze

      # The parts this drawing keeps of the last drawing to move the count on: whether it was in
      # perspective only where the points' nearness is not worked out as it is first read (see
      # SEEN_STRIDE).
      def turn_parts = @corners_in_a_loop ? TURN_PARTS - [:in_perspective] : TURN_PARTS

      # The perspective `screen_spot` asks for, which fills no face. Where the nearness is worked out as
      # the point routine turns a point, a question asks for it, so the drawings in perspective that
      # follow read the points it turned; where it is worked out as it is first read, none.
      def spot_perspective = @corners_in_a_loop ? :none : :every_8_pixels

      # The variable the routine reads the viewer's +part+ from.
      def viewer_var(part) = name(:"viewer_#{part}")

      # A SHAPE DRAWN WHERE THE GAME SAYS IT STANDS, facing the way the game says (`draw_place ...,
      # at:, facing:`): one shape, a robot, drawn several times a pass, each where it is now. The
      # stance is a spot and three arrows, kept as a viewer's are (VIEWER_PARTS), the shape's own
      # right, up and ahead as they lie in the place.
      #
      # The points are not moved. The VIEWER is, into the shape's own arrows: where the viewer stands
      # measured from the shape's spot along the shape's arrows, and each of the viewer's arrows
      # measured along them too. A point measured from that viewer along those arrows lands where
      # the point moved into the place would land measured from the real viewer, because measuring
      # along three square arrows of length one and measuring back is no change at all. The old
      # first-person games of moving models drew them the same way: the viewer handed to the model's
      # frame once, eighteen products a drawing, and not one more for each point.
      #
      # So the point routine, the cut, the projection and the fill are the fixed place's own, and
      # the points the drawing turns are stamped as seen by a viewer that differs from one stance to
      # the next (TURN_PARTS): a second robot never reads the points the first one turned.
      #
      # The stance's arrows are taken as given, as `eye.face` takes them. Arrows that are not
      # square and of length one draw the shape bent, the same bent on every lowering.
      AXES = %i[x y z].freeze
      ARROWS = %i[right up ahead].freeze

      # WHERE A SHAPE STANDS AND WHICH WAY IT FACES, as the game gave them: +spot+ three fraction
      # nodes (x, y, z), and +arrows+ three of three (right, up, ahead), or nil for a shape that faces
      # as the place was declared.
      Stance = Data.define(:spot, :arrows) do
        def turned? = !arrows.nil?

        # Each part of the stance (VIEWER_PARTS) with its node: the spot, then the arrows'.
        def parts
          spot_parts = AXES.zip(spot)
          return spot_parts unless turned?

          spot_parts + ARROWS.zip(arrows).flat_map { |arrow, numbers| AXES.map { |axis| :"#{arrow}_#{axis}" }.zip(numbers) }
        end
      end

      # The variables the stance routine keeps its work in: where the viewer stands from the stance's
      # spot, and one of the viewer's arrows measured along the stance's while the arrow is still read.
      VIEWER_FROM_STANCE_VARS = %i[dx dy dz].freeze
      MEASURED_ARROW_VARS = %i[at_x at_y at_z].freeze

      def stance_var(part) = name(:"stance_#{part}")

      def stance_routine = name(:stance)

      # The stance routine: the viewer, handed over as it is, moved into the shape's own arrows from
      # the stance in the stance variables. A routine of its own, made once for the place, so each
      # drawing of a turned shape costs a call rather than eighteen products written out again.
      def stance_statements
        offsets = VIEWER_FROM_STANCE_VARS.zip(AXES).map do |offset, axis|
          Build.set(name(offset), Build.binop(:-, Build.var_ref(viewer_var(axis)), Build.var_ref(stance_var(axis))))
        end
        from_stance = VIEWER_FROM_STANCE_VARS.map { |offset| var(offset) }
        spot = AXES.zip(ARROWS).map { |axis, arrow| Build.set(viewer_var(axis), dot_with_stance_arrow(from_stance, arrow)) }
        arrows = ARROWS.flat_map do |viewer_arrow|
          parts = AXES.map { |axis| :"#{viewer_arrow}_#{axis}" }
          from = parts.map { |part| Build.var_ref(viewer_var(part)) }
          measured = MEASURED_ARROW_VARS.zip(ARROWS).map do |held, arrow|
            Build.set(name(held), dot_with_stance_arrow(from, arrow))
          end
          measured + parts.zip(MEASURED_ARROW_VARS).map { |part, held| Build.set(viewer_var(part), var(held)) }
        end
        offsets + spot + arrows
      end

      # What a drawing of a shape standing at +stance+ does once the viewer is handed over as it is:
      # for a turned stance, keep it in the stance variables and call the stance routine; for one
      # facing as the place does, move the viewer by the spot alone, three subtractions.
      def stance_handover_statements(stance)
        unless stance.turned?
          return AXES.zip(stance.spot).map do |axis, node|
            Build.set(viewer_var(axis), Build.binop(:-, Build.var_ref(viewer_var(axis)), node))
          end
        end

        stance.parts.map { |part, node| Build.set(stance_var(part), node) } + [Build.call(stance_routine)]
      end

      # The variable the routine reads the view's +part+ from.
      def view_var(part) = name(:"view_#{part}")

      # The variables holding the rectangle a face is held to: +edge+ is left, top, right or
      # bottom. The view's own edges, unless the game gave a window.
      def clip_var(edge) = name(:"clip_#{edge}")

      # A FACE WHOLLY PAST ONE EDGE OF ITS WINDOW draws nothing, so it is passed over before it is
      # tested for which way it faces or filled: a face beside the view, or behind a doorway's window,
      # is most of the faces of a place seen from inside, and a game of rooms draws each room through
      # the window its doorway makes. Every corner gets an outcode, a bit for each edge it is past
      # (the clipping test of Cohen and Sutherland), and the bits every corner shares say an edge the
      # whole face is past.
      #
      # The corners tested are the ones the face is cut to at the near limit, each as the cut hands it
      # to the fill (#cut_edge, #corner_statements), so a face reaching behind the viewer is tested on
      # the corners it is drawn with. The test is folded into the cut, which has each corner's place on
      # the screen in hand already: a few comparisons a corner, and no reading of the seen list again.
      # Testing before the cut would spare the cut's copying for a face passed over, but costs every
      # face seen a second reading of its corners, and cannot test a face that crosses the limit.
      #
      # "Past" leaves a little to spare, so that no fill loses a pixel to it, whether it takes a pixel
      # when the face covers its middle (Reference#exec_fill_face) or rounds each corner to the nearest
      # pixel first and takes the pixels between. Each edge has a line, in sixteenths of a pixel,
      # worked out once a drawing (#outside_line_statements):
      #
      #   - LEFT and RIGHT: where a row starts and ends is found along an edge of the face, a hair
      #     either way of where the corners land. A face whose corners are all more than seven
      #     sixteenths left of the window's left edge (or nine past its right) has no pixel inside,
      #     however its corners are rounded.
      #   - TOP: a face ending less than half a pixel into the window's first row does not cover the
      #     row's middle; but a corner exactly half a pixel in rounds to the row's end, so a fill that
      #     rounds takes the row. So a face is past the top only when its lowest corner is less than
      #     half a pixel (eight sixteenths) into the row.
      #   - BOTTOM: a face whose corners are all at or past seven sixteenths above the window's
      #     bottom edge covers no row's middle above it, and none rounds to a row above it.
      #
      # A face kept by the test may still draw nothing; the fill finds that out as before.
      #
      # Each edge: which side of the window it is, the corner's number it is tested on (x or y), its
      # outcode bit (as a shift), its line's offset from the window's side in sixteenths, and the
      # comparison that says a corner is past it.
      OutcodeEdge = Data.define(:side, :axis, :shift, :sixteenths, :past) do
        def bit = 1 << shift
      end
      OUTCODE_EDGES = [OutcodeEdge.new(side: :left, axis: :x, shift: 0, sixteenths: -7, past: :<),
                       OutcodeEdge.new(side: :right, axis: :x, shift: 1, sixteenths: 9, past: :>=),
                       OutcodeEdge.new(side: :top, axis: :y, shift: 2, sixteenths: 8, past: :<),
                       OutcodeEdge.new(side: :bottom, axis: :y, shift: 3, sixteenths: -7, past: :>=)].freeze
      ALL_OUTCODE_BITS = OUTCODE_EDGES.sum(&:bit)

      # The variable holding the line a corner is past +side+ beyond (see OUTCODE_EDGES).
      def outside_line_var(side) = name(:"outside_#{side}")

      # A cut corner's part in the face's outcode: the bits of OUTCODE_EDGES the corner in at_x, at_y
      # (its place on the screen) is past, kept in the outcode variable, which starts a face as
      # ALL_OUTCODE_BITS. Once a corner leaves it nought, nothing a later corner is past can change
      # that, so the comparisons are made only while it is not: a face in view is usually told by its
      # first corner, and its others cost a test each.
      def corner_outcode_statements
        [Build.if_(var(:outcode), Build.set(name(:outcode), Build.binop(:&, var(:outcode), corner_outcode_bits)))]
      end

      # The bits of OUTCODE_EDGES the corner in at_x, at_y is past.
      def corner_outcode_bits
        OUTCODE_EDGES.map do |edge|
          past = Build.binop(edge.past, var(:"at_#{edge.axis}"), Build.var_ref(outside_line_var(edge.side)))
          edge.shift.zero? ? past : Build.binop(:<<, past, edge.shift)
        end.reduce { |code, bit| Build.binop(:|, code, bit) }
      end

      # Each edge's line, worked out once a drawing's clip variables are set from +held+, the value
      # each side of the window was set from, by side: a number where the side is one, so a drawing
      # with no window works nothing out, and from the clip variable where the game works it out.
      def outside_line_statements(held)
        return [] unless @outcode_test

        OUTCODE_EDGES.map do |edge|
          side = held.fetch(edge.side)
          line = if side.kind == :int
                   Build.int((side.value * SUBPIXEL) + edge.sixteenths)
                 else
                   Build.binop(:+, Build.binop(:*, Build.var_ref(clip_var(edge.side)), SUBPIXEL), edge.sixteenths)
                 end
          Build.set(outside_line_var(edge.side), line)
        end
      end

      # The variables the spot routine reads its point from and leaves its answers in.
      def spot_point_var = name(:spot_point)
      def spot_answer_var(part) = name(:"spot_#{part}")

      # Every variable the routines keep their work in, the viewer's and the view's included.
      def variables
        VIEWER_PARTS.map { |part| viewer_var(part) } + VIEW_PARTS.map { |part| view_var(part) } +
          CLIP_EDGES.map { |edge| clip_var(edge) } + outcode_variables +
          %i[face listed base slot picture point seen_point dx dy dz count along area each next drawing
             at_x at_y at_z at_u at_v at_light spot_point spot_x spot_y spot_behind turn_changed].map { |part| name(part) } +
          turn_parts.map { |part| turn_var(part) } + corner_variables
      end

      # The variables the test for a face outside its window keeps its work in, where the drawing makes it.
      def outcode_variables
        return [] unless @outcode_test

        OUTCODE_EDGES.map { |edge| outside_line_var(edge.side) } + [name(:outcode)]
      end

      # The variables a face's corners are worked in: four of each kind written out, or the loop's own.
      def corner_variables
        return %i[corner corner_at other_at corner_point other_point corner_z other_z].map { |part| name(part) } if @corners_in_a_loop

        CORNERS.times.flat_map { |k| TURNED_FIELDS.map { |field| turned_var(field, k) } }
      end

      # The variable counting the drawings, which marks the points each has turned (see SEEN_STRIDE).
      def drawing_var = name(:drawing)

      # The count moved on as a drawing starts, once its viewer and view are handed over, when what a
      # point's turn is worked out from differs from the last drawing's that moved it on (see
      # TURN_PARTS); each part that differs is kept for the next. The count routine's statements, which
      # every drawing of the place, and every `screen_spot`, calls. The near limit kept is the one the
      # points were turned with, which the point routine reads (see THE NEAR LIMIT NEED NOT MATCH).
      # Whether the points were turned in perspective, where it is kept, is the same: points turned with
      # their nearness serve a drawing that reads none.
      def drawing_count_statements
        changed = name(:turn_changed)
        kept = %i[near in_perspective] & turn_parts
        [Build.set(changed, 0),
         *MATCHED_TURN_PARTS.map do |part|
           Build.if_(Build.binop(:!=, Build.var_ref(turn_var(part)), turn_part_now(part)),
                     Build.set(changed, 1), Build.set(turn_var(part), turn_part_now(part)))
         end,
         Build.if_(Build.binop(:<, turn_part_now(:near), Build.var_ref(turn_var(:near))), Build.set(changed, 1)),
         *(kept.include?(:in_perspective) ? [Build.if_(Build.binop(:>, in_perspective, Build.var_ref(turn_var(:in_perspective))), Build.set(changed, 1))] : []),
         Build.if_(Build.var_ref(changed), Build.add(drawing_var, 1),
                   *kept.map { |part| Build.set(turn_var(part), turn_part_now(part)) })]
      end

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
        return face_loop_statements if @corners_in_a_loop

        [Build.set(name(:base), Build.binop(:*, var(:face), FACE_STRIDE)),
         Build.set(name(:slot), Build.table_get(faces_table, face_field(FACE_SLOT))),
         Build.set(name(:picture), Build.binop(:+, var(:slot), Build.list_get(slots_list, var(:slot)))),
         *CORNERS.times.flat_map { |k| turned_corner(k) },
         *cut_and_fill(*CORNERS.times.flat_map { |k| cut_edge(k) })]
      end

      # THE SAME FACE WITH ITS CORNERS IN A LOOP, for a console whose processor runs its code from a
      # small cache (Console::Description#code_cache_bytes). Written out four times over, the corners'
      # work is most of a face's code, and a face's code bigger than the cache is fetched from memory
      # again for every face; once, in a loop, it stays in the cache from one face to the next. Each
      # pass of the loop reads its corner from where the turning left it (the seen list) and from the
      # faces table, rather than from variables of its own, so the numbers are the same numbers, worked
      # out by the same sums in the same order: first every corner turned, then every edge cut.
      def face_loop_statements
        corner = var(:corner)
        [Build.set(name(:base), Build.binop(:*, var(:face), FACE_STRIDE)),
         Build.set(name(:slot), Build.table_get(faces_table, face_field(FACE_SLOT))),
         Build.set(name(:picture), Build.binop(:+, var(:slot), Build.list_get(slots_list, var(:slot)))),
         Build.repeat(CORNERS, name(:corner),
                      Build.set(name(:corner_point), Build.table_get(faces_table, corner_at(corner))),
                      Build.if_(Build.binop(:!=, Build.list_get(stamps_list, var(:corner_point)), var(:drawing)),
                                Build.set(name(:seen_point), var(:corner_point)),
                                Build.call(point_routine))),
         *cut_and_fill(Build.repeat(CORNERS, name(:corner), *looped_cut_edge))]
      end

      # What follows the turning: the face cut by +cut+, and if three corners or more are left and they
      # are not wholly past one edge of the window (OUTCODE_EDGES), tested for which way it faces and filled.
      def cut_and_fill(*cut)
        test_and_fill = [*front_test, fill_when_seen]
        return [Build.set(name(:count), 0), *cut, Build.if_(Build.binop(:>=, var(:count), 3), *test_and_fill)] unless @outcode_test

        [Build.set(name(:outcode), ALL_OUTCODE_BITS),
         Build.set(name(:count), 0),
         *cut,
         Build.if_(Build.binop(:>=, var(:count), 3), Build.if_(Build.binop(:==, var(:outcode), 0), *test_and_fill))]
      end

      # The edge from the loop's corner to the next, cut at the near limit, as #cut_edge cuts it.
      def looped_cut_edge
        following = Build.binop(:&, Build.binop(:+, var(:corner), 1), CORNERS - 1)
        here = var(:corner_at)
        there = var(:other_at)
        seen = ->(point, at) { Build.list_get(seen_list, Build.binop(:+, Build.binop(:*, var(point), SEEN_STRIDE), at)) }
        z_here = var(:corner_z)
        z_there = var(:other_z)
        in_front_here = Build.binop(:>=, z_here, Build.var_ref(view_var(:near)))
        in_front_there = Build.binop(:>=, z_there, Build.var_ref(view_var(:near)))
        moved = lambda do |from, to|
          Build.binop(:+, from, Build.mul_fix(Build.binop(:-, to, from), var(:along), 16))
        end
        on_face = ->(at, offset) { Build.table_get(faces_table, Build.binop(:+, at, offset)) }
        light = ->(at, point) { looped_corner_light(at, point) }
        corner = ->(offset) { Build.binop(:+, Build.binop(:*, var(:count), Nodes::FillFace::CORNER_NUMBERS), offset) }
        [Build.set(name(:corner_at), corner_at(var(:corner))),
         Build.set(name(:other_at), corner_at(following)),
         Build.set(name(:corner_point), Build.table_get(faces_table, here)),
         Build.set(name(:other_point), Build.table_get(faces_table, there)),
         Build.set(name(:corner_z), seen.call(:corner_point, 2)),
         Build.set(name(:other_z), seen.call(:other_point, 2)),
         Build.if_(in_front_here,
                   *corner_on_screen_statements(corner, seen.call(:corner_point, SEEN_ACROSS), seen.call(:corner_point, SEEN_DOWN)),
                   Build.list_set(corners_list, corner.call(2), on_face.call(here, 1)),
                   Build.list_set(corners_list, corner.call(3), on_face.call(here, 2)),
                   Build.if_(in_perspective,
                             nearness_filled(Build.binop(:+, Build.binop(:*, var(:corner_point), SEEN_STRIDE), SEEN_NEARNESS), z_here),
                             Build.list_set(corners_list, corner.call(4), seen.call(:corner_point, SEEN_NEARNESS))),
                   *(@shading ? [Build.list_set(corners_list, corner.call(5), light.call(here, :corner_point))] : []),
                   Build.add(name(:count), 1)),
         Build.if_(Build.binop(:!=, in_front_here, in_front_there),
                   Build.set(name(:along), Build.div_fix(Build.binop(:-, Build.var_ref(view_var(:near)), z_here),
                                                         Build.binop(:-, z_there, z_here), 16)),
                   Build.set(name(:at_x), moved.call(seen.call(:corner_point, 0), seen.call(:other_point, 0))),
                   Build.set(name(:at_y), moved.call(seen.call(:corner_point, 1), seen.call(:other_point, 1))),
                   Build.set(name(:at_u), moved.call(on_face.call(here, 1), on_face.call(there, 1))),
                   Build.set(name(:at_v), moved.call(on_face.call(here, 2), on_face.call(there, 2))),
                   *(@shading ? [Build.set(name(:at_light), moved.call(light.call(here, :corner_point), light.call(there, :other_point)))] : []),
                   Build.set(name(:at_z), Build.var_ref(view_var(:near))),
                   Build.call(corner_routine))]
      end

      # Where in the faces table the face being drawn keeps corner +corner+ (a value): its point's number,
      # then u, v and its light.
      def corner_at(corner) = Build.binop(:+, var(:base), Build.binop(:+, Build.binop(:*, corner, CORNER_FIELDS), 1))

      # #corner_light for the corner whose entry starts at +at+ and whose point's number is in +point+.
      def looped_corner_light(at, point)
        own = Build.table_get(faces_table, Build.binop(:+, at, 3))
        @point_lights ? Build.binop(:+, own, Build.list_get(@point_lights, var(point))) : own
      end

      # Where the point whose number is in the spot's point variable lands, turned and projected
      # as a face's corner is: the pixel whose middle is first at or past it, across and down, and
      # whether it is nearer than the near limit (then both are nought).
      #
      # It turns the point as a drawing does, through the count and the point routine, and leaves it in
      # the seen list stamped: a game of rooms asks where a room's corners land before it draws the room,
      # and the drawing then reads them rather than turning them again.
      def spot_statements
        number = var(:seen_point)
        seen = ->(at) { Build.list_get(seen_list, Build.binop(:+, Build.binop(:*, number, SEEN_STRIDE), at)) }
        pixel = ->(sixteenths) { Build.shift_right(Build.binop(:+, sixteenths, (SUBPIXEL / 2) - 1), 4) }
        [Build.set(name(:seen_point), Build.clamped(Build.var_ref(spot_point_var), 0, @points - 1)),
         Build.call(count_routine),
         Build.if_(Build.binop(:!=, Build.list_get(stamps_list, number), var(:drawing)), Build.call(point_routine)),
         Build.set(name(:at_z), seen.call(2)),
         Build.set(spot_answer_var(:x), 0),
         Build.set(spot_answer_var(:y), 0),
         Build.set(spot_answer_var(:behind), 1),
         Build.if_(Build.binop(:>=, var(:at_z), Build.var_ref(view_var(:near))),
                   Build.set(spot_answer_var(:x), pixel.call(seen.call(SEEN_ACROSS))),
                   Build.set(spot_answer_var(:y), pixel.call(seen.call(SEEN_DOWN))),
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
         Build.if_(Build.binop(:>=, var(:at_z), Build.var_ref(turn_var(:near))),
                   Build.list_set(seen_list, Build.binop(:+, seen, SEEN_ACROSS), landed(:+, :at_x, :middle_x)),
                   Build.list_set(seen_list, Build.binop(:+, seen, SEEN_DOWN), landed(:-, :at_y, :middle_y)),
                   nearness_or_nought(Build.binop(:+, seen, SEEN_NEARNESS))),
         Build.list_set(stamps_list, number, var(:drawing))]
      end

      # The nearness of the point just turned into the seen list at +place+: where the corners are worked
      # in a loop, for a drawing in perspective, and nought for any other, meaning not worked out yet;
      # otherwise for points the count turns in perspective (see SEEN_STRIDE).
      def nearness_or_nought(place)
        return Build.if_(Build.var_ref(turn_var(:in_perspective)), Build.list_set(seen_list, place, nearness)) unless @corners_in_a_loop

        kept = Build.if_(in_perspective, Build.list_set(seen_list, place, nearness))
        kept.else = Build.else_(Build.list_set(seen_list, place, 0))
        kept
      end

      # A drawing in perspective reading the nearness of a corner whose point was turned without it: the
      # nearness worked out from +z+, how far ahead the point is, and kept in the seen list at +place+.
      def nearness_filled(place, z)
        Build.if_(Build.binop(:==, Build.list_get(seen_list, place), 0),
                  Build.set(name(:at_z), z),
                  Build.list_set(seen_list, place, nearness))
      end

      # The corner routine: the corner in at_x, at_y, at_z (turned, at_z at or past the near
      # limit), at_u and at_v put on the screen and added to the corner list.
      def corner_statements
        at = var(:count)
        place = ->(offset) { Build.binop(:+, Build.binop(:*, at, Nodes::FillFace::CORNER_NUMBERS), offset) }
        [*corner_on_screen_statements(place, landed(:+, :at_x, :middle_x), landed(:-, :at_y, :middle_y)),
         Build.list_set(corners_list, place.call(2), var(:at_u)),
         Build.list_set(corners_list, place.call(3), var(:at_v)),
         Build.if_(in_perspective, Build.list_set(corners_list, place.call(4), nearness)),
         *(@shading ? [Build.list_set(corners_list, place.call(5), var(:at_light))] : []),
         Build.add(name(:count), 1)]
      end

      # One over how far ahead the corner in at_z is, with 26 bits of fraction, which a picture in
      # perspective steps across a face (see Nodes::FillFace). Worked out only for a drawing in
      # perspective, the only one that reads it: a divide a point.
      def nearness = Build.div_fix(1 << 16, var(:at_z), 26)

      def in_perspective = Build.binop(:!=, Build.var_ref(view_var(:perspective)), Nodes::FillFace::PERSPECTIVE_NONE)

      private

      def name(part) = self.class.name_of(@place, part)

      def var(part) = Build.var_ref(name(part))

      def turned_var(field, k) = name(:"#{field}#{k}")

      def turned(field, k) = Build.var_ref(turned_var(field, k))

      # A cut corner's place on the screen, +across+ and +down+ (values), put in the corner list where
      # +place+ (the corner's number in the list for an offset) says, and its bits taken into the face's
      # outcode (#corner_outcode_statements). Where the drawing tests the window, the place is kept in
      # at_x and at_y as it is put in the list, which costs less than reading the list back to test it.
      def corner_on_screen_statements(place, across, down)
        unless @outcode_test
          return [Build.list_set(corners_list, place.call(0), across), Build.list_set(corners_list, place.call(1), down)]
        end

        [Build.set(name(:at_x), across), Build.set(name(:at_y), down),
         Build.list_set(corners_list, place.call(0), var(:at_x)), Build.list_set(corners_list, place.call(1), var(:at_y)),
         *corner_outcode_statements]
      end

      # The variable keeping +part+ of TURN_PARTS as the last drawing to move the count on had it.
      def turn_var(part) = name(:"turn_#{part}")

      # +part+ of TURN_PARTS as this drawing has it.
      def turn_part_now(part)
        return in_perspective if part == :in_perspective
        return Build.var_ref(view_var(part)) if TURN_VIEW_PARTS.include?(part)

        Build.var_ref(viewer_var(part))
      end

      # How far +numbers+ (three values, along the place's x, y and z) reach along the stance's arrow
      # +arrow+: three products added, as #along measures a point along the viewer's.
      def dot_with_stance_arrow(numbers, arrow)
        numbers.zip(AXES).map do |number, axis|
          Build.mul_fix(number, Build.var_ref(stance_var(:"#{arrow}_#{axis}")), 16)
        end.reduce { |sum, product| Build.binop(:+, sum, product) }
      end

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
         Build.set(turned_var(:v, k), Build.table_get(faces_table, face_field(first + 2))),
         *(@shading ? [Build.set(turned_var(:light, k), corner_light(first + 3, number))] : [])]
      end

      # A corner's light: the face's own for that corner, and what the game adds to its point as
      # it runs. The fill holds it to the lightest a corner can be.
      def corner_light(field, number)
        own = Build.table_get(faces_table, face_field(field))
        @point_lights ? Build.binop(:+, own, Build.list_get(@point_lights, number)) : own
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
                   *corner_on_screen_statements(corner, Build.list_get(seen_list, Build.binop(:+, seen, SEEN_ACROSS)),
                                     Build.list_get(seen_list, Build.binop(:+, seen, SEEN_DOWN))),
                   Build.list_set(corners_list, corner.call(2), turned(:u, k)),
                   Build.list_set(corners_list, corner.call(3), turned(:v, k)),
                   Build.if_(in_perspective,
                             Build.list_set(corners_list, corner.call(4),
                                            Build.list_get(seen_list, Build.binop(:+, seen, SEEN_NEARNESS)))),
                   *(@shading ? [Build.list_set(corners_list, corner.call(5), turned(:light, k))] : []),
                   Build.add(name(:count), 1)),
         Build.if_(Build.binop(:!=, in_front(k), in_front(other)),
                   Build.set(name(:along), through),
                   *(@shading ? %i[x y u v light] : %i[x y u v]).map { |field| Build.set(name(:"at_#{field}"), moved.call(field)) },
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
        corner = lambda do |index, axis|
          Build.list_get(corners_list, Build.binop(:+, Build.binop(:*, index, Nodes::FillFace::CORNER_NUMBERS), axis))
        end
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
        perspective = Build.var_ref(view_var(:perspective))
        fill = Build.fill_face(@pictures, var(:picture), corners_list, var(:count), edges, perspective: perspective)
        seen = Build.binop(:or, Build.binop(:>, var(:area), 0), Build.binop(:==, Build.var_ref(view_var(:both_sides)), 1))
        return Build.if_(seen, fill) unless @shading

        # A place with a shading is drawn lit unless the drawing says not.
        lit = Build.fill_face(@pictures, var(:picture), corners_list, var(:count), edges, perspective: perspective,
                                                                                      shading: @shading)
        lit_or_not = Build.if_(Build.binop(:==, Build.var_ref(view_var(:lit)), 1), lit)
        lit_or_not.else = Build.else_(fill)
        Build.if_(seen, lit_or_not)
      end
    end
  end
end
