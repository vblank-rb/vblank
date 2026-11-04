# frozen_string_literal: true

module VBlank
  class Builder
    # A FIRST-PERSON VIEW OF A PLACE MADE OF FLAT FACES: a place declared once (`place`), a spot
    # it is seen from (`viewer`), and the verb that draws it as that spot sees it (`draw_place`).
    # A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # The work of drawing is statements every target runs (IR::PlaceDrawing), held in two routines
    # made once for each place the game draws, the first time it draws it.
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
      # @param faces [Object] which faces to draw (not made yet)
      # @param window [Object] edges the game works out as it runs (not made yet)
      def draw_place(name, seen_by:, perspective: :none, near: NEAR, view_angle: VIEW_ANGLE, both_sides: false,
                     faces: nil, window: nil)
        shape = (@places || {})[name] or
          raise ArgumentError, "draw_place needs a place. There is no place :#{name}. To fix this, declare it " \
                               "with `place :#{name} do ... end` first."
        refuse_unknown_viewer!(name, seen_by)
        refuse_perspective_not_made!(perspective)
        refuse_setting_not_made!(:faces, faces)
        refuse_setting_not_made!(:window, window)
        refuse_bad_near!(near)
        refuse_bad_view_angle!(view_angle)
        refuse_place_on_plain_screen!(name)

        drawing = place_drawing(shape)
        view = place_view(DSL::Fraction.scale(near, DSL::Fraction::DEFAULT_BITS), view_angle, both_sides)
        record(Build.draw_place(name, seen_by.name, *place_handover(drawing, seen_by, view), Build.call(drawing.routine),
                                perspective: perspective, near: view.near, view_angle: view_angle,
                                both_sides: both_sides == true))
      end

      private

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

      def refuse_setting_not_made!(setting, given)
        return if given.nil?

        raise ArgumentError, "draw_place was given #{setting}:. This build does not make that setting yet. To fix " \
                             "this, remove #{setting}:."
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
      end

      # The drawing of +shape+, its routines declared the first time the game draws it.
      def place_drawing(shape)
        drawing = IR::PlaceDrawing.new(shape.name, faces: shape.faces.length, pictures: shape.slots)
        @places_drawn ||= {}
        return drawing if @places_drawn.key?(shape.name)

        @places_drawn[shape.name] = true
        drawing.variables.each { |variable| ensure_var(variable) }
        declare_func(drawing.routine) { drawing.statements.each { |statement| record(statement) } }
        declare_func(drawing.corner_routine) { drawing.corner_statements.each { |statement| record(statement) } }
        drawing
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
