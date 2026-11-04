# frozen_string_literal: true

module VBlank
  module IR
    # HOW A PLACE MADE OF FLAT FACES IS DRAWN, written once as statements every target runs
    # (see Nodes::DrawPlace). A place is points in space and faces that join four of them, and
    # drawing it as a viewer sees it is three sums for each corner of each face:
    #
    #   - TURN the point to the viewer. Take the viewer's spot away from the point, and measure
    #     what is left along the viewer's three arrows (right, up and ahead). That gives how far
    #     the point is to the viewer's right, above them and in front of them.
    #   - PROJECT it onto the screen. A point twice as far ahead looks half as far from the
    #     middle of the view, so how far right it lands is how far right it is divided by how
    #     far ahead it is, made bigger by how wide an angle the view shows.
    #   - FILL the face between its four corners with its picture (Nodes::FillFace).
    #
    # WHY THESE ARE STATEMENTS AND NOT A ROUTINE OF EACH TARGET'S OWN. Every target that works
    # the sums out itself runs these same statements, so every one of them turns and projects
    # each point to the same bits, and only the fill is written again for each. Every number is a
    # fraction with sixteen bits, as a game's fractions are, and every product and quotient goes
    # through Int32.mul_fix and Int32.div_fix, where the rounding is settled.
    #
    # A FACE THAT REACHES NEARER THAN THE NEAR LIMIT IS NOT DRAWN AT ALL. Cutting it at the limit
    # makes a face of five corners from one of four, and that is not made yet; until it is, a
    # face beside or behind the viewer is left out whole.
    #
    # WHERE A POINT CAN LAND. A point a little in front of the viewer and far to one side lands
    # far off the screen, and the fill's sums would overflow on it, so where a corner lands is
    # held to LANDING_LIMIT pixels either side of the screen's corner. A face that reaches past
    # that is drawn bent; a face beside the viewer reaches that far only when it is nearer than
    # the near limit, and is not drawn anyway.
    class PlaceDrawing
      # A place's faces table keeps, for each face, the number of its picture slot and then,
      # for each of its four corners, the number of its point and where it falls on the
      # picture (u, v).
      FACE_SLOT = 0
      CORNER_FIELDS = 3
      FACE_STRIDE = 1 + (4 * CORNER_FIELDS)
      # ...and its points table three numbers a point: x, y, z.
      POINT_STRIDE = 3

      # One whole: a fraction keeps sixteen bits below the point.
      ONE = 1 << 16
      # How much finer than a pixel a corner's place on the screen is kept: sixteenths.
      SUBPIXEL = 16
      LANDING_LIMIT = 2048 * SUBPIXEL

      # The viewer's twelve numbers, in the order a viewer keeps them: its spot, then its right,
      # up and ahead arrows.
      VIEWER_PARTS = %i[x y z right_x right_y right_z up_x up_y up_z ahead_x ahead_y ahead_z].freeze
      # What the routine is told about the view before each drawing: its edges and its middle,
      # and how far a point one whole to the side at one whole ahead lands from the middle.
      VIEW_PARTS = %i[left top right bottom middle_x middle_y focal].freeze

      # The name of +part+ of place +place+ (a table, a list, a variable or the routine).
      def self.name_of(place, part) = Messages::MadeNames.make(:place_part, place: place, part: part)

      # +place+ is the place's name, +faces+ how many it has, +pictures+ the pictures its slots
      # can show (a slot holds a number counting into these), and +near+ how near a corner may
      # be, as a fraction with sixteen bits.
      def initialize(place, faces:, pictures:, near:)
        @place = place
        @faces = faces
        @pictures = pictures
        @near = near
      end

      def routine = name(:draw)
      def points_table = name(:points)
      def faces_table = name(:faces)
      def slots_list = name(:slots)

      # The variable the routine reads the viewer's +part+ from.
      def viewer_var(part) = name(:"viewer_#{part}")

      # The variable the routine reads the view's +part+ from.
      def view_var(part) = name(:"view_#{part}")

      # Every variable the routine keeps its work in, the viewer's and the view's included.
      def variables
        VIEWER_PARTS.map { |part| viewer_var(part) } + VIEW_PARTS.map { |part| view_var(part) } +
          %i[face base picture seen point dx dy dz ahead across down].map { |part| name(part) } +
          4.times.flat_map { |k| %i[x y u v].map { |field| corner_var(field, k) } }
      end

      # The routine's statements: every face, in the order the place declares them.
      def statements
        [Build.repeat(@faces, name(:face),
                      Build.set(name(:base), Build.binop(:*, Build.var_ref(name(:face)), FACE_STRIDE)),
                      Build.set(name(:picture),
                                Build.list_get(slots_list, Build.table_get(faces_table, face_field(FACE_SLOT)))),
                      Build.set(name(:seen), 1),
                      *4.times.flat_map { |k| corner_statements(k) },
                      Build.if_(Build.binop(:==, Build.var_ref(name(:seen)), 1), *fills))]
      end

      private

      def name(part) = self.class.name_of(@place, part)

      def corner_var(field, k) = name(:"#{field}#{k}")

      # The faces table's entry +offset+ along the face being drawn.
      def face_field(offset) = Build.binop(:+, Build.var_ref(name(:base)), offset)

      # Corner +k+ of the face being drawn: where it falls on the picture, and where it lands on
      # the screen — or the face marked unseen, when the corner is nearer than the near limit.
      def corner_statements(k)
        first = 1 + (k * CORNER_FIELDS)
        point = Build.binop(:*, Build.table_get(faces_table, face_field(first)), POINT_STRIDE)
        turned = Build.if_(Build.binop(:<, Build.var_ref(name(:ahead)), @near), Build.set(name(:seen), 0))
        turned.else = Build.else_(*projection(k))
        [Build.set(name(:point), point),
         *%i[dx dy dz].each_with_index.map do |part, axis|
           at = Build.binop(:+, Build.var_ref(name(:point)), axis)
           Build.set(name(part), Build.binop(:-, Build.table_get(points_table, at), Build.var_ref(viewer_var(VIEWER_PARTS[axis]))))
         end,
         Build.set(name(:ahead), along(:ahead)),
         turned,
         Build.set(corner_var(:u, k), Build.table_get(faces_table, face_field(first + 1))),
         Build.set(corner_var(:v, k), Build.table_get(faces_table, face_field(first + 2)))]
      end

      # How far the point the corner names is along one of the viewer's arrows: the point's
      # offset from the viewer measured along the arrow, three products added.
      def along(arrow)
        %i[x y z].map do |axis|
          Build.mul_fix(Build.var_ref(name(:"d#{axis}")), Build.var_ref(viewer_var(:"#{arrow}_#{axis}")), 16)
        end.reduce { |sum, product| Build.binop(:+, sum, product) }
      end

      # Where corner +k+ lands on the screen, in sixteenths of a pixel: across from the middle
      # by how far right it is over how far ahead, and down from it by how far up (the screen's
      # rows count downward).
      def projection(k)
        [Build.set(name(:across), along(:right)),
         Build.set(name(:down), along(:up)),
         Build.set(corner_var(:x, k), landed(:+, :across, :middle_x)),
         Build.set(corner_var(:y, k), landed(:-, :down, :middle_y))]
      end

      def landed(op, offset, middle)
        ratio = Build.div_fix(Build.var_ref(name(offset)), Build.var_ref(name(:ahead)), 16)
        spot = Build.binop(op, Build.var_ref(view_var(middle)), Build.mul_fix(ratio, Build.var_ref(view_var(:focal)), 16))
        Build.clamped(spot, -LANDING_LIMIT, LANDING_LIMIT)
      end

      # The fill, once for each picture the face can show: the one its slot holds now.
      def fills
        corners = 4.times.map { |k| %i[x y u v].map { |field| Build.var_ref(corner_var(field, k)) } }
        edges = %i[left top right bottom].map { |part| Build.var_ref(view_var(part)) }
        @pictures.each_with_index.map do |picture, number|
          Build.if_(Build.binop(:==, Build.var_ref(name(:picture)), number), Build.fill_face(picture, corners, edges))
        end
      end
    end
  end
end
