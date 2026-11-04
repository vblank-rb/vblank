# frozen_string_literal: true

module VBlank
  class Builder
    # A FIRST-PERSON VIEW OF A PLACE MADE OF FLAT FACES: a place declared once (`place`), a spot
    # it is seen from (`viewer`), and the verb that draws it as that spot sees it (`draw_place`).
    # A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # The work of drawing is statements every target runs (IR::PlaceDrawing), held in routines made
    # once for each place the game draws, the first time it draws it. Where one point lands
    # (`screen_spot`) is one more routine, made only for a game that asks.
    module Places
      # How near a point may be before a face is cut there, by default: a quarter of a whole.
      NEAR = 0.25

      # How wide an angle the view shows, in degrees across, by default.
      VIEW_ANGLE = 90

      # The settings `perspective:` takes, and the ones this build makes.
      PERSPECTIVES = %i[none every_8_pixels every_pixel].freeze
      PERSPECTIVES_MADE = %i[none].freeze

      # A place made of flat faces (see DSL::Place). The block declares its points and faces:
      #
      #   place :cube do
      #     a = point -1.0,  1.0, 1.0
      #     b = point  1.0,  1.0, 1.0
      #     c = point  1.0, -1.0, 1.0
      #     d = point -1.0, -1.0, 1.0
      #     face a, b, c, d, picture: :crate, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]]
      #   end
      #
      # @param name [Symbol] the place's name
      # @return [DSL::Place]
      def place(name, &block)
        raise ArgumentError, "place :#{name} needs a block that declares its points and faces." unless block

        refuse_unfit_name!("place", name)
        if (@places ||= {}).key?(name)
          raise ArgumentError, "There is already a place :#{name}. To fix this, give each place its own name."
        end

        shape = DSL::Place.new(name, @images)
        shape.instance_exec(&block)
        refuse_empty_place!(shape)
        declare_place_data(shape)
        @places[name] = shape
      end

      # The spot a place is seen from, and which way it faces (see DSL::Viewer). +at+ is [x, y, z];
      # +facing+ is the viewer's three arrows, each three numbers.
      #
      #   eye = viewer :eye, at: [0.0, 0.0, -4.0]
      #
      # @return [DSL::Viewer]
      def viewer(name, at:, facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] })
        refuse_unfit_name!("viewer", name)
        if (@viewers ||= {}).key?(name)
          raise ArgumentError, "There is already a viewer :#{name}. To fix this, give each viewer its own name."
        end

        seen = DSL::Viewer.new(self, name)
        DSL::Viewer.starting_numbers(name, at, facing).zip(seen.variables).each { |number, variable| var(variable, number) }
        seen.scratch_variables.each { |variable| var(variable, 0) }
        @viewers[name] = seen
      end

      # Draw place +name+ as +seen_by+ sees it, on the screen or inside the area an `inside` holds
      # drawing to. A face is cut where it comes nearer than +near+ wholes to the viewer, and one
      # seen from behind is not drawn unless +both_sides+.
      #
      # @param name [Symbol] the place
      # @param seen_by [DSL::Viewer] the viewer
      # @param perspective [Symbol] how a picture is laid across a face that leans away
      # @param near [Numeric] how near a point may be, in wholes
      # @param view_angle [Integer] how wide the view is, in degrees across
      # @param both_sides [Boolean] draw a face seen from behind too
      # A GAME THAT KNOWS WHAT IT CAN SEE draws only that. +faces+ is a list of face numbers (what
      # `face` gives back) the game fills as it runs, drawn in its order, a later face over an
      # earlier one; and +window+ is the rectangle they are held to, four numbers the game works
      # out (left, top, right, bottom, the right and bottom just past the last pixel drawn). A game
      # made of rooms finds the rooms seen through each doorway with `screen_spot`, and draws each
      # with its own faces and window, far rooms first.
      #
      # @param faces [DSL::List] which faces to draw, in order; all of them when not given
      # @param window [Array] four numbers or Values: the edges faces are held to as the game runs
      def draw_place(name, seen_by:, perspective: :none, near: NEAR, view_angle: VIEW_ANGLE, both_sides: false,
                     faces: nil, window: nil)
        shape = known_place(name, "draw_place")
        refuse_unknown_viewer!(name, seen_by)
        refuse_perspective_not_made!(perspective)
        refuse_bad_faces!(name, faces)
        window_nodes = window && window_edges(name, window)
        refuse_bad_near!(near)
        refuse_bad_view_angle!(view_angle)
        refuse_place_on_plain_screen!(name)

        drawing = place_drawing(shape)
        place_draw_routines(drawing)
        view = place_view(DSL::Fraction.scale(near, DSL::Fraction::DEFAULT_BITS), view_angle, both_sides)
        drawn =faces ? drawing.listed_statements(faces.name) : [Build.call(drawing.routine)]
        record(Build.draw_place(name, seen_by.name, *place_handover(drawing, seen_by, view),
                                *place_clip(drawing, view, window_nodes), Build.add(drawing.drawing_var, 1), *drawn,
                                perspective: perspective, near: view.near, view_angle: view_angle,
                                both_sides: both_sides == true, faces: faces&.name, window: window_nodes))
      end

      # Where point +point+ of place +name+ lands on the screen as +seen_by+ sees it, worked out
      # as the game runs exactly as `draw_place` works out a face's corner, with the same +near+
      # and +view_angle+ (and the same `inside` area). A game uses it to find the rectangle a
      # doorway covers, to draw the room beyond it held to that (`draw_place ..., window:`).
      #
      #   corner = screen_spot :rooms, door_top_left, seen_by: eye
      #   left = corner.x if corner.x < left
      #
      # Each `screen_spot` line keeps its answers in variables of its own.
      #
      # @param point [Integer, DSL::Value] a point's number, what `point` gave back
      # @return [DSL::ScreenSpot]
      def screen_spot(name, point, seen_by:, near: NEAR, view_angle: VIEW_ANGLE)
        shape = known_place(name, "screen_spot")
        refuse_unknown_viewer!(name, seen_by)
        refuse_unknown_spot_point!(shape, point)
        refuse_bad_near!(near)
        refuse_bad_view_angle!(view_angle)

        drawing = place_drawing(shape)
        place_spot_routine(drawing)
        view = place_view(DSL::Fraction.scale(near, DSL::Fraction::DEFAULT_BITS), view_angle, false)
        @screen_spots = (@screen_spots || 0) + 1
        answers = DSL::ScreenSpot::ANSWERS.to_h do |part|
          variable = IR::PlaceDrawing.name_of(name, :"spot#{@screen_spots}_#{part}")
          ensure_var(variable)
          [part, variable]
        end
        record(Build.set(drawing.spot_point_var, DSL::Value.node_for(point)))
        place_handover(drawing, seen_by, view).each { |statement| record(statement) }
        record(Build.call(drawing.spot_routine))
        answers.each { |part, variable| record(Build.copy(variable, drawing.spot_answer_var(part))) }
        DSL::ScreenSpot.new(answers.transform_values { |variable| value_handle_for(variable) })
      end

      private

      def known_place(name, verb)
        (@places || {})[name] or
          raise ArgumentError, "#{verb} needs a place. There is no place :#{name}. To fix this, declare it " \
                               "with `place :#{name} do ... end` first."
      end

      def refuse_bad_faces!(name, faces)
        return if faces.nil? || (faces.is_a?(DSL::List) && faces.fraction_bits.nil?)

        raise ArgumentError, "draw_place :#{name} was given faces: #{faces.inspect}. faces: needs a list of face " \
                             "numbers. To fix this, make one with `list :seen, capacity: 64`, put in the numbers " \
                             "that `face` gives, and give faces: that list."
      end

      # The window's four edges as values, refused unless they are four whole numbers.
      def window_edges(name, window)
        unless window.is_a?(Array) && window.length == 4
          raise ArgumentError, "draw_place :#{name} was given window: #{window.inspect}. window: needs four numbers: " \
                               "left, top, right and bottom. To fix this, give `window: [left, top, right, bottom]`."
        end

        window.map do |edge|
          whole = edge.is_a?(Integer) || (edge.is_a?(DSL::Value) && !edge.fraction?)
          unless whole
            raise ArgumentError, "draw_place :#{name} was given a window edge #{edge.inspect}. Each edge of a window " \
                                 "is a whole number of pixels. To fix this, give a whole number, or a variable " \
                                 "that holds one."
          end

          DSL::Value.node_for(edge)
        end
      end

      def refuse_unknown_spot_point!(shape, point)
        return if point.is_a?(DSL::Value) && !point.fraction?
        return if point.is_a?(Integer) && point.between?(0, shape.points.length - 1)

        raise ArgumentError, "screen_spot :#{shape.name} was given the point #{point.inspect}. The place has no " \
                             "point #{point.inspect}. To fix this, give a number that `point` gave in this place."
      end

      # A place's and a viewer's own variables are named after it, then two underscores, so its
      # name cannot hold two underscores in a row or end in one (Messages::MadeNames::POOL_NAME).
      def refuse_unfit_name!(what, name)
        return if name.is_a?(Symbol) && Messages::MadeNames::POOL_NAME.match?(name.to_s)

        raise ArgumentError, "#{what} #{name.inspect} has a name that cannot be used. A #{what}'s name is a " \
                             "symbol with no two underscores in a row, and it does not end in an underscore. " \
                             "To fix this, give a name like :#{what == 'place' ? 'cave' : 'eye'}."
      end

      def refuse_empty_place!(shape)
        return unless shape.faces.empty?

        raise ArgumentError, "place :#{shape.name} has no faces. To fix this, add a face with `face`."
      end

      def refuse_unknown_viewer!(name, seen_by)
        return if seen_by.is_a?(DSL::Viewer)

        raise ArgumentError, "draw_place :#{name} needs seen_by: a viewer, and was given #{seen_by.inspect}. To " \
                             "fix this, make one with `eye = viewer :eye, at: [0.0, 0.0, -4.0]` and give seen_by: eye."
      end

      def refuse_perspective_not_made!(perspective)
        unless PERSPECTIVES.include?(perspective)
          raise ArgumentError, "draw_place was given perspective: #{perspective.inspect}. The settings are " \
                               "#{PERSPECTIVES.map(&:inspect).join(', ')}. To fix this, use one of them."
        end
        return if PERSPECTIVES_MADE.include?(perspective)

        raise ArgumentError, "draw_place was given perspective: #{perspective.inspect}. This build does not make " \
                             "that setting yet. To fix this, use perspective: :none."
      end

      def refuse_bad_near!(near)
        return if near.is_a?(Numeric) && near.positive? && near <= 16

        raise ArgumentError, "draw_place was given near: #{near.inspect}. The near limit is a distance more than 0 " \
                             "and not more than 16. To fix this, give a number like 0.25."
      end

      def refuse_bad_view_angle!(degrees)
        return if degrees.is_a?(Integer) && degrees.between?(10, 170)

        raise ArgumentError, "draw_place was given view_angle: #{degrees.inspect}. The view angle is a whole " \
                             "number of degrees from 10 to 170. To fix this, give a number like 90."
      end

      def refuse_place_on_plain_screen!(name)
        return if @screen_mode == :bitmap && @tear_free

        raise ArgumentError, "draw_place :#{name} is on a screen that is not `screen :bitmap, tear_free: true`. A " \
                             "place is drawn over a whole frame. On a screen with one page the player sees each " \
                             "frame drawn. To fix this, write `screen :bitmap, tear_free: true` first."
      end

      # The place's points and faces as tables, and the slots its faces show their pictures
      # through as a list. A slot holds how far along the place's pictures its picture is from
      # the slot's own, so a list full of nought shows each slot its own picture: that is what
      # the list is declared holding, wherever the place is declared and whatever puts the
      # game's state back as declared (`start_over`).
      def declare_place_data(shape)
        table(IR::PlaceDrawing.name_of(shape.name, :points), shape.points_table, width: :word, signed: true)
        table(IR::PlaceDrawing.name_of(shape.name, :faces), shape.faces_table, width: :word, signed: true)
        list(IR::PlaceDrawing.name_of(shape.name, :slots), capacity: shape.slots.length, full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :corners),
             capacity: IR::Nodes::FillFace::MOST_CORNERS * IR::Nodes::FillFace::CORNER_NUMBERS, full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :seen), capacity: shape.points.length * IR::PlaceDrawing::SEEN_STRIDE,
                                                          full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :stamps), capacity: shape.points.length, full_of: 0)
      end

      # The drawing of +shape+, its variables declared the first time the game draws it or asks
      # where one of its points lands.
      def place_drawing(shape)
        drawing = IR::PlaceDrawing.new(shape.name, faces: shape.faces.length, points: shape.points.length,
                                                   pictures: shape.slots)
        @place_variables ||= {}
        @place_variables[shape.name] ||= drawing.variables.each { |variable| ensure_var(variable) }
        drawing
      end

      # The routines that draw the place, declared the first time the game draws it.
      def place_draw_routines(drawing)
        declare_place_routine(drawing.routine, drawing.statements)
        declare_place_routine(drawing.face_routine, drawing.face_statements)
        declare_place_routine(drawing.point_routine, drawing.point_statements)
        declare_place_routine(drawing.corner_routine, drawing.corner_statements)
      end

      # The routine that works out where one point lands, declared the first time a game asks, so
      # a game that never asks carries none of it, and a game that only asks carries nothing that
      # draws.
      def place_spot_routine(drawing) = declare_place_routine(drawing.spot_routine, drawing.spot_statements)

      def declare_place_routine(name, statements)
        @place_routines ||= {}
        return if @place_routines.key?(name)

        @place_routines[name] = true
        declare_func(name) { statements.each { |statement| record(statement) } }
      end

      # The rectangle faces are held to: the view's own, or the game's window held inside it.
      def place_clip(drawing, view, window)
        view_edges = [view.left, view.top, view.right, view.bottom]
        IR::PlaceDrawing::CLIP_EDGES.each_with_index.map do |edge, k|
          held = if window
                   low, high = k.even? ? [view.left, view.right] : [view.top, view.bottom]
                   Build.clamped(window[k], low, high)
                 else
                   Build.int(view_edges[k])
                 end
          Build.set(drawing.clip_var(edge), held)
        end
      end

      # The view the place is drawn into: the `inside` area drawing is held to, or the screen.
      def place_view(near, view_angle, both_sides)
        left, top, width, height = @inside_area || [0, 0, screen_width, screen_height]
        IR::PlaceDrawing::View.over(left, top, width, height, degrees: view_angle, near: near, both_sides: both_sides)
      end

      # What the routine is told before it draws: where the viewer is and which way it faces, and
      # the view.
      def place_handover(drawing, seen_by, view)
        seen_by.variables.zip(IR::PlaceDrawing::VIEWER_PARTS).map do |variable, part|
          Build.copy(drawing.viewer_var(part), variable)
        end + view.to_h.map { |part, number| Build.set(drawing.view_var(part), Build.int(number)) }
      end
    end
  end
end
