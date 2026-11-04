# frozen_string_literal: true

module VBlank
  class Builder
    # A FIRST-PERSON VIEW OF A PLACE MADE OF FLAT FACES: a place declared once (`place`), a spot
    # it is seen from (`viewer`), and the verb that draws it as that spot sees it (`draw_place`).
    # A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # The work of drawing is statements every target runs (IR::PlaceDrawing), held in a routine
    # made once for each place the game draws, the first time it draws it.
    module Places
      # How near a corner may be before its face is left out: a quarter of a whole.
      NEAR = 0.25

      # How wide an angle the view shows, in degrees across.
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

        seen = DSL::Viewer.new(name)
        DSL::Viewer.starting_numbers(name, at, facing).zip(seen.variables).each { |number, variable| var(variable, number) }
        @viewers[name] = seen
      end

      # Draw place +name+ as +seen_by+ sees it, on the screen or inside the area an `inside` holds
      # drawing to. Faces nearer than the near limit are left out.
      #
      # @param name [Symbol] the place
      # @param seen_by [DSL::Viewer] the viewer
      # @param perspective [Symbol] how a picture is laid across a face that leans away
      def draw_place(name, seen_by:, perspective: :none)
        shape = (@places || {})[name] or
          raise ArgumentError, "draw_place needs a place. There is no place :#{name}. To fix this, declare it " \
                               "with `place :#{name} do ... end` first."
        refuse_unknown_viewer!(name, seen_by)
        refuse_perspective_not_made!(perspective)
        refuse_place_on_plain_screen!(name)

        drawing = place_drawing(shape)
        record(Build.draw_place(name, seen_by.name, *place_handover(drawing, seen_by), Build.call(drawing.routine),
                                perspective: perspective))
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
          raise ArgumentError, "draw_place was given perspective: #{perspective.inspect}. It takes " \
                               "#{PERSPECTIVES.map(&:inspect).join(', ')}."
        end
        return if PERSPECTIVES_MADE.include?(perspective)

        raise ArgumentError, "draw_place was given perspective: #{perspective.inspect}. This build does not make " \
                             "that yet. To fix this, use perspective: :none."
      end

      def refuse_place_on_plain_screen!(name)
        return if @screen_mode == :bitmap && @tear_free

        raise ArgumentError, "draw_place :#{name} is on a screen that is not `screen :bitmap, tear_free: true`. A " \
                             "place is drawn over a whole frame. On any other screen the player sees it drawn, or " \
                             "it cannot be drawn. To fix this, write `screen :bitmap, tear_free: true` first."
      end

      # The place's points and faces as tables, and the slots its faces show their pictures
      # through as a list, each slot showing its own picture to start with. The slots are set
      # where the place is written, after the list is made, which for a place declared before
      # the game loop is once, as the game starts.
      def declare_place_data(shape)
        table(IR::PlaceDrawing.name_of(shape.name, :points), shape.points_table, width: :word, signed: true)
        table(IR::PlaceDrawing.name_of(shape.name, :faces), shape.faces_table, width: :word, signed: true)
        slots = IR::PlaceDrawing.name_of(shape.name, :slots)
        list(slots, capacity: shape.slots.length, full_of: 0)
        shape.slots.each_index { |slot| record(Build.list_set(slots, Build.int(slot), Build.int(slot))) unless slot.zero? }
      end

      # The drawing of +shape+, its routine declared the first time the game draws it.
      def place_drawing(shape)
        drawing = IR::PlaceDrawing.new(shape.name, faces: shape.faces.length, pictures: shape.slots,
                                                   near: DSL::Fraction.scale(NEAR, DSL::Fraction::DEFAULT_BITS))
        @places_drawn ||= {}
        return drawing if @places_drawn.key?(shape.name)

        @places_drawn[shape.name] = true
        drawing.variables.each { |variable| ensure_var(variable) }
        declare_func(drawing.routine) { drawing.statements.each { |statement| record(statement) } }
        drawing
      end

      # What the routine is told before it draws: where the viewer is and which way it faces, and
      # the view's edges, its middle and how wide it sees.
      def place_handover(drawing, seen_by)
        left, top, width, height = @inside_area || [0, 0, screen_width, screen_height]
        focal = ((width / 2.0) / Math.tan(VIEW_ANGLE * Math::PI / 360) * IR::PlaceDrawing::SUBPIXEL).round
        view = { left: left, top: top, right: left + width, bottom: top + height,
                 middle_x: ((left * 2) + width) * IR::PlaceDrawing::SUBPIXEL / 2,
                 middle_y: ((top * 2) + height) * IR::PlaceDrawing::SUBPIXEL / 2, focal: focal }
        seen_by.variables.zip(IR::PlaceDrawing::VIEWER_PARTS).map do |variable, part|
          Build.copy(drawing.viewer_var(part), variable)
        end + view.map { |part, number| Build.set(drawing.view_var(part), Build.int(number)) }
      end
    end
  end
end
