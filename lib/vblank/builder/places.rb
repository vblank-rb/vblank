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

      # The settings `perspective:` takes. The default works the picture's place out exactly every
      # sixteen pixels across a row, or every eight where the face leans away steeply close by,
      # and steps straight between; :every_8_pixels works it out every eight, :every_pixel at each
      # pixel, and :none stretches the picture straight between a row's ends.
      PERSPECTIVES = IR::Nodes::FillFace::PERSPECTIVE_SPANS.keys.freeze
      PERSPECTIVE = IR::Nodes::FillFace::DEFAULT_PERSPECTIVE

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
      # A place lit by a shading (`shading:`, see #shading) is drawn lit: each face's corners give
      # their light (`face ..., light: [...]`), the place's point_lights add to it as the game runs,
      # and each pixel is the colour the shading gives for the light it has reached.
      #
      # A PLACE FROM DATA, as a game reads a level from a file, is the same place without the block:
      # +points+ each [x, y, z], and +faces+ each a Hash of what `face` takes, with its points by their
      # number in +points+. +pictures+ lists pictures first, as `pictures` does in the block, so a
      # face can name its picture by its number among them, as a level file numbers its pictures:
      #
      #   place :mine, points: [[-1.0, 1.0, 2.0], ...], pictures: %i[rock moss],
      #                faces: [{ points: [0, 1, 2, 3], picture: 1, on_picture: [...], light: 0.5 }, ...]
      #
      # @param name [Symbol] the place's name
      # @param shading [Symbol, nil] the shading the place is lit by
      # @param points [Array<Array<Numeric>>, nil] each point's [x, y, z], for a place from data
      # @param faces [Array<Hash>, nil] each face's points:, picture:, on_picture: and light:, for a place from data
      # A PLACE FROM THE DATA PACK, as a port reads a level from the player's copy, gives +points+
      # and +faces+ as slots of the pack and +faces_used+ as the number of the pack that says how
      # many faces are used (see Builder::PackPlaces):
      #
      #   place :mine, points: pack[:points], faces: pack[:faces], faces_used: pack[:sizes].number(0),
      #                pictures: %i[rock moss]
      #
      # @param pictures [Array<Symbol>] pictures the place lists before its faces name any
      # @param faces_used [DSL::PackNumber, nil] for a place from the pack, how many of its faces are used
      # @return [DSL::Place]
      def place(name, shading: nil, points: nil, faces: nil, pictures: [], faces_used: nil, &block)
        refuse_unfit_place_source!(name, block, points, faces)
        from_pack = pack_place_given?(points, faces, faces_used)
        refuse_unfit_name!("place", name)
        if (@places ||= {}).key?(name)
          raise ArgumentError, "There is already a place :#{name}. To fix this, give each place its own name."
        end
        refuse_unknown_shading!(name, shading)

        shape = DSL::Place.new(name, @images)
        shape.pictures(*pictures)
        if from_pack
          declare_place_from_pack(shape, points, faces, faces_used)
        else
          block ? shape.instance_exec(&block) : shape.declare_from_data(points, faces)
          refuse_empty_place!(shape)
          declare_place_data(shape)
        end
        if shading
          shape.shading = shading
          shape.point_lights = list(IR::PlaceDrawing.name_of(name, :point_lights), capacity: shape.point_count,
                                                                                   full_of: 0.0)
        end
        @places[name] = shape
      end

      # A GAME'S OWN SHADING: for each level of light, darkest first, what each of the game's colours
      # becomes, as the game's tables give it. +colors+ are the game's colours (numbers, as `rgb` gives,
      # or names), and each of +levels+ is one number for each of them: the place in +colors+ of
      # the colour it becomes at that level. A place lit by it (`place :mine, shading: :fade`) draws
      # each pixel as the shading gives for the light the pixel has reached; a colour not in
      # +colors+ stays as it is.
      #
      #   shading :fade, colors: palette, levels: tables   # 32 levels, as a game's tables give them
      #
      # @param name [Symbol] the shading's name
      # @param colors [Array] the game's colours
      # A SHADING FROM THE DATA PACK gives +colors+ as a slot of colours and +levels+ as a slot of
      # bytes, each level's places one after another, darkest first (see Builder::PackPlaces):
      #
      #   shading :fade, colors: pack[:palette], levels: pack[:fades]
      #
      # @param levels [Array<Array<Integer>>] for each level, darkest first, a place in +colors+ for each colour
      def shading(name, colors:, levels:)
        refuse_unfit_name!("shading", name)
        @shadings ||= {}
        raise ArgumentError, "There is already a shading :#{name}. To fix this, give each shading its own name." if @shadings.key?(name)
        return @shadings[name] = record(pack_shading(name, colors, levels)) if pack_shading_given?(name, colors, levels)

        values = colors.map { |color| Graphics::Color.resolve(color) }
        refuse_bad_levels!(name, values, levels)
        @shadings[name] = record(Build.shading(name, values, levels))
      end

      # The spot a place is seen from, and which way it faces (see DSL::Viewer). +at+ is [x, y, z];
      # +facing+ is the viewer's three arrows, each three numbers.
      #
      #   eye = viewer :eye, at: [0.0, 0.0, -4.0]
      #
      # Where a port's viewer starts is in the level it reads, so +at+ (three numbers) and +facing+
      # (nine: right, up, ahead) may each be numbers of the data pack (see Builder::PackPlaces):
      #
      #   eye = viewer :eye, at: pack[:start], facing: pack[:start_facing]
      #
      # @return [DSL::Viewer]
      def viewer(name, at:, facing: FACING_AS_DECLARED)
        refuse_unfit_name!("viewer", name)
        if (@viewers ||= {}).key?(name)
          raise ArgumentError, "There is already a viewer :#{name}. To fix this, give each viewer its own name."
        end

        seen = DSL::Viewer.new(self, name)
        from_pack = viewer_start_in_pack(name, at, facing)
        written = DSL::Viewer.starting_numbers(name, from_pack.at ? [0, 0, 0] : at, from_pack.facing ? FACING_AS_DECLARED : facing)
        written.zip(seen.variables).each { |number, variable| var(variable, number) }
        seen.scratch_variables.each { |variable| var(variable, 0) }
        emit_viewer_start_from_pack(seen, from_pack)
        @viewers[name] = seen
      end

      # The way a viewer faces where the game gives none: along the place's own arrows.
      FACING_AS_DECLARED = Ractor.make_shareable({ right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] })

      # Draw place +name+ as +seen_by+ sees it, on the screen or inside the area an `inside` holds
      # drawing to. A face is cut where it comes nearer than +near+ wholes to the viewer, and one
      # seen from behind is not drawn unless +both_sides+.
      #
      # @param name [Symbol] the place
      # @param seen_by [DSL::Viewer] the viewer
      # @param perspective [Symbol] how a picture is laid across a face that leans away: the near
      #   rooms of a place in perspective and the far ones with :none, as the old games did, is a
      #   draw_place for each
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
      # @param lit [Boolean] for a place with a shading, draw it lit (the default) or as its pictures are
      # A SHAPE DRAWN WHERE THE GAME PUTS IT, a robot flying in a room: +at+ is where the place's own
      # middle stands now, three numbers or values the game works out, and +facing+ which way the
      # place's own arrows point, as `viewer` takes them (`bot.facing` hands a viewer's over). Each
      # drawing stands it afresh, so one shape is drawn as many times a pass as the game likes.
      # @param at [Array, nil] where the shape stands, [x, y, z]; nil where it was declared
      # @param facing [Hash, nil] the shape's right:, up: and ahead: arrows; nil as it was declared
      def draw_place(name, seen_by:, perspective: PERSPECTIVE, near: NEAR, view_angle: VIEW_ANGLE, both_sides: false,
                     faces: nil, window: nil, lit: true, at: nil, facing: nil)
        shape = known_place(name, "draw_place")
        refuse_unknown_viewer!(name, seen_by)
        refuse_unknown_perspective!(perspective)
        refuse_bad_faces!(name, faces)
        window_nodes = window && window_edges(name, window)
        refuse_bad_near!(near)
        refuse_bad_view_angle!(view_angle)
        refuse_place_on_plain_screen!(name)
        stance = make_stance("draw_place", name, at, facing)
        refuse_pack_place_moved!("draw_place", shape) if stance

        drawing = place_drawing(shape)
        place_draw_routines(drawing)
        view = place_view(DSL::Fraction.scale(near, DSL::Fraction::DEFAULT_BITS), view_angle, both_sides, perspective,
                          lit: lit && !shape.shading.nil?)
        drawn = faces ? drawing.listed_statements(faces.name) : [Build.call(drawing.routine)]
        drawn = [*place_clip(drawing, view, window_nodes), drawing.count_statement, *drawn]
        drawn = place_in_view_test(drawing, shape, drawn) if stance
        record(Build.draw_place(name, seen_by.name, *place_handover(drawing, seen_by, view, stance), *drawn,
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
      # Each `screen_spot` line keeps its answers in variables of its own. A shape drawn where the
      # game puts it (`draw_place ..., at:, facing:`) is asked about with the same +at+ and +facing+.
      #
      # @param point [Integer, DSL::Value] a point's number, what `point` gave back
      # @return [DSL::ScreenSpot]
      def screen_spot(name, point, seen_by:, near: NEAR, view_angle: VIEW_ANGLE, at: nil, facing: nil)
        shape = known_place(name, "screen_spot")
        refuse_unknown_viewer!(name, seen_by)
        refuse_unknown_spot_point!(shape, point)
        refuse_bad_near!(near)
        refuse_bad_view_angle!(view_angle)
        stance = make_stance("screen_spot", name, at, facing)
        refuse_pack_place_moved!("screen_spot", shape) if stance

        drawing = place_drawing(shape)
        place_spot_routine(drawing)
        view = place_view(DSL::Fraction.scale(near, DSL::Fraction::DEFAULT_BITS), view_angle, false, drawing.spot_perspective)
        @screen_spots = (@screen_spots || 0) + 1
        answers = DSL::ScreenSpot::ANSWERS.to_h do |part|
          variable = IR::PlaceDrawing.name_of(name, :"spot#{@screen_spots}_#{part}")
          ensure_var(variable)
          [part, variable]
        end
        record(Build.set(drawing.spot_point_var, DSL::Value.node_for(point)))
        place_handover(drawing, seen_by, view, stance).each { |statement| record(statement) }
        record(Build.call(drawing.spot_routine))
        answers.each { |part, variable| record(Build.copy(variable, drawing.spot_answer_var(part))) }
        DSL::ScreenSpot.new(answers.transform_values { |variable| value_handle_for(variable) })
      end

      # Point slot +slot+ of place +name+ at picture +to+, from here on: every face that starts with
      # the slot's picture shows +to+ instead, from the next drawing, until the slot is pointed again.
      # A door slides through its frames, a wall of lava runs.
      #
      #   place :hall do
      #     pictures :door0, :door1, :door2   # numbered in a row, the frames no face starts with among them
      #     face ..., picture: :door0, ...
      #   end
      #   change_picture :hall, slot: :door0, to: :door2                                # by name
      #   change_picture :hall, slot: :door0, to: frame + hall.picture_number(:door0)   # worked out
      #
      # +slot+ is named for the picture it starts with (or is that picture's number). +to+ is a
      # picture the place lists, by name or number, or a whole-number value the game works out: the
      # number of one of the place's pictures (DSL::Place#picture_number), where a number that is
      # not one is passed over and the slot keeps what it shows.
      #
      # A slot keeps how far along the place's pictures it is from its own, so pointing it back is
      # the same as never pointing it (see #declare_place_data).
      #
      # @param name [Symbol] the place
      # @param slot [Symbol, Integer] the slot, by the picture it starts with or its number
      # @param to [Symbol, Integer, DSL::Value] the picture it shows from now on
      def change_picture(name, slot:, to:)
        shape = known_place(name, "change_picture")
        slot_number = shape.slot_number(slot)
        slots = IR::PlaceDrawing.name_of(name, :slots)
        if to.is_a?(DSL::Value)
          refuse_fraction_picture!(name, to)
          chosen = IR::PlaceDrawing.name_of(name, :chosen_picture)
          ensure_var(chosen)
          picture = Build.var_ref(chosen)
          listed = Build.binop(:and, Build.binop(:>=, picture, 0), Build.binop(:<, picture, shape.listed_pictures.length))
          record(Build.set(chosen, DSL::Value.node_for(to)))
          record(Build.if_(listed, Build.list_set(slots, slot_number, Build.binop(:-, picture, slot_number))))
        else
          record(Build.list_set(slots, slot_number, shape.picture_number(to) - slot_number))
        end
      end

      private

      def refuse_fraction_picture!(name, to)
        return unless to.fraction?

        raise ArgumentError, "change_picture :#{name} was given to: a fraction. A picture's number is a whole number. " \
                             "To fix this, give a whole number, or a variable that holds one."
      end

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
        return if point.is_a?(Integer) && point.between?(0, shape.point_count - 1)

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

        raise ArgumentError, "place :#{shape.name} has no faces. To fix this, add a face with `face`, or give " \
                             "faces: one face or more."
      end

      # A place is declared by a block or from points: and faces:, one way and not both.
      def refuse_unfit_place_source!(name, block, points, faces)
        data = !points.nil? || !faces.nil?
        if block && data
          raise ArgumentError, "place :#{name} was given both a block and data (points: or faces:). To fix this, " \
                               "declare the place one way: with a block, or with points: and faces:."
        end
        return if block || (!points.nil? && !faces.nil?)

        unless data
          raise ArgumentError, "place :#{name} needs a block that declares its points and faces, or points: and " \
                               "faces:. To fix this, give one of them."
        end
        given, missing = points.nil? ? %w[faces: points:] : %w[points: faces:]
        raise ArgumentError, "place :#{name} was given #{given} and no #{missing}. A place from data needs both " \
                             "points: and faces:. To fix this, give #{missing} too."
      end

      def refuse_unknown_viewer!(name, seen_by)
        return if seen_by.is_a?(DSL::Viewer)

        raise ArgumentError, "draw_place :#{name} needs seen_by: a viewer, and was given #{seen_by.inspect}. To " \
                             "fix this, make one with `eye = viewer :eye, at: [0.0, 0.0, -4.0]` and give seen_by: eye."
      end

      def refuse_unknown_shading!(name, shading)
        return if shading.nil? || (@shadings || {}).key?(shading)

        raise ArgumentError, "place :#{name} is lit by shading: #{shading.inspect}, and there is no such shading. To " \
                             "fix this, declare it with `shading :#{shading}, colors: [...], levels: [...]` first."
      end

      def refuse_bad_levels!(name, colors, levels)
        fits = levels.is_a?(Array) && !levels.empty? &&
               levels.all? { |level| level.is_a?(Array) && level.length == colors.length && level.all? { |place| place.is_a?(Integer) && place.between?(0, colors.length - 1) } }
        return if fits

        raise ArgumentError, "shading :#{name} has levels: that do not fit its #{colors.length} colours. Each level is a " \
                             "list of #{colors.length} numbers, each the place of a colour in colors:. To fix this, give " \
                             "one or more such lists, darkest first."
      end

      def refuse_unknown_perspective!(perspective)
        return if PERSPECTIVES.include?(perspective)

        raise ArgumentError, "draw_place was given perspective: #{perspective.inspect}. The settings are " \
                             "#{PERSPECTIVES.map(&:inspect).join(', ')}. To fix this, use one of them."
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
        declare_place_lists(shape)
      end

      # The lists a place's drawing works in, wherever its points and faces come from.
      def declare_place_lists(shape)
        list(IR::PlaceDrawing.name_of(shape.name, :slots), capacity: shape.listed_pictures.length, full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :corners),
             capacity: IR::Nodes::FillFace::MOST_CORNERS * IR::Nodes::FillFace::CORNER_NUMBERS, full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :seen), capacity: shape.point_count * IR::PlaceDrawing::SEEN_STRIDE,
                                                          full_of: 0)
        list(IR::PlaceDrawing.name_of(shape.name, :codes), capacity: shape.point_count, full_of: 0)
      end

      # The drawing of +shape+, its variables declared the first time the game draws it or asks
      # where one of its points lands.
      def place_drawing(shape)
        drawing = IR::PlaceDrawing.new(shape.name, faces: shape.face_count, points: shape.point_count,
                                                   pictures: shape.listed_pictures, shading: shape.shading,
                                                   point_lights: shape.point_lights&.name,
                                                   corners_in_a_loop: !@console.code_cache_bytes.nil?,
                                                   outcode_test: !@console.face_fill_skips_outside_window,
                                                   fill_by_row_middles: @console.face_fill_by_row_middles,
                                                   faces_used: shape.faces_used_table,
                                                   numbers_held: shape.from_pack?)
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
        declare_place_routine(drawing.count_routine, drawing.drawing_count_statements)
      end

      # +drawn+, the statements drawing a shape at a spot, held behind the test of whether any of
      # the shape can show (IR::PlaceDrawing, A SHAPE WHOLLY OUT OF VIEW IS PASSED OVER WHOLE), whose
      # routine is declared the first time the game draws the shape at a spot.
      def place_in_view_test(drawing, shape, drawn)
        unless @place_routines&.key?(drawing.in_view_routine)
          drawing.in_view_variables.each { |variable| ensure_var(variable) }
          declare_place_routine(drawing.in_view_routine, drawing.in_view_statements(IR::PlaceDrawing::Reach.around(shape.points)))
        end
        [Build.call(drawing.in_view_routine), Build.if_(Build.var_ref(drawing.in_view_var), *drawn)]
      end

      # The routine that works out where one point lands, declared the first time a game asks, so
      # a game that never asks carries none of it, and a game that only asks carries nothing that
      # draws.
      # It turns its point as a drawing does, so it brings the point routine and the count with it.
      def place_spot_routine(drawing)
        declare_place_routine(drawing.spot_routine, drawing.spot_statements)
        declare_place_routine(drawing.point_routine, drawing.point_statements)
        declare_place_routine(drawing.count_routine, drawing.drawing_count_statements)
      end

      def declare_place_routine(name, statements)
        @place_routines ||= {}
        return if @place_routines.key?(name)

        @place_routines[name] = true
        declare_func(name) { statements.each { |statement| record(statement) } }
      end

      # The rectangle faces are held to: the view's own, or the game's window held inside it; and
      # the lines a face lying wholly past one of its edges is told by (IR::PlaceDrawing::OUTCODE_EDGES).
      def place_clip(drawing, view, window)
        view_edges = [view.left, view.top, view.right, view.bottom]
        held = IR::PlaceDrawing::CLIP_EDGES.each_with_index.to_h do |edge, k|
          if window
            low, high = k.even? ? [view.left, view.right] : [view.top, view.bottom]
            [edge, Build.clamped(window[k], low, high)]
          else
            [edge, Build.int(view_edges[k])]
          end
        end
        held.map { |edge, node| Build.set(drawing.clip_var(edge), node) } + drawing.outside_line_statements(held)
      end

      # The view the place is drawn into: the `inside` area drawing is held to, or the screen.
      def place_view(near, view_angle, both_sides, perspective = :none, lit: false)
        left, top, width, height = @inside_area || [0, 0, screen_width, screen_height]
        IR::PlaceDrawing::View.over(left, top, width, height, degrees: view_angle, near: near, both_sides: both_sides,
                                                              perspective: perspective, lit: lit)
      end

      # What the routine is told before it draws: where the viewer is and which way it faces, and
      # the view. For a shape standing where the game puts it (+stance+, from #make_stance), the
      # viewer handed over is then moved into the shape's own arrows
      # (IR::PlaceDrawing#stance_handover_statements).
      #
      # The viewer and the view are handed over by a routine of the place's own for each viewer and view
      # the game draws or asks with, which writes only what differs from what the last handover left
      # (IR::PlaceDrawing, HANDED OVER UNCHANGED): one call where each `draw_place` and `screen_spot` line
      # would otherwise copy every number of the viewer and the view.
      def place_handover(drawing, seen_by, view, stance = nil)
        if stance&.turned?
          declare_place_routine(drawing.stance_routine, drawing.stance_statements)
          stance.parts.each { |part, _| ensure_var(drawing.stance_var(part)) }
        end
        [Build.call(place_handover_routine(drawing, seen_by, view)), *(stance ? drawing.stance_handover_statements(stance) : [])]
      end

      # The routine handing +seen_by+ and +view+ over to +drawing+, declared the first time they are handed
      # over together. Each view the place is handed is numbered from 1, so the 0 its variable starts at
      # is none.
      def place_handover_routine(drawing, seen_by, view)
        @place_handovers ||= Hash.new { |all, place| all[place] = {} }
        @place_views ||= Hash.new { |all, place| all[place] = {} }
        routines = @place_handovers[drawing.routine]
        views = @place_views[drawing.routine]
        routines.fetch([seen_by.name, view]) do
          number = views[view] ||= views.length + 1
          name = drawing.handover_routine(routines.length + 1)
          declare_place_routine(name, drawing.viewer_handover_statements(seen_by.variables) +
                                      drawing.view_handover_statements(view, number))
          routines[[seen_by.name, view]] = name
        end
      end

      # The IR::PlaceDrawing::Stance +at+ and +facing+ give, each number a fraction node, or nil for
      # a shape drawn where it was declared. Refused in plain words unless +at+ is three numbers or
      # values within the place's reach and +facing+ three arrows of three, written ones square
      # and of length one.
      def make_stance(verb, name, at, facing)
        return nil if at.nil? && facing.nil?

        spot = at.nil? ? [0, 0, 0] : at
        refuse_bad_stance_spot!(verb, name, spot)
        refuse_bad_facing!(verb, name, facing) if facing
        fraction = ->(number) { DSL::Viewer.fraction_node(number, "#{verb} :#{name}") }
        arrows = facing&.values_at(*IR::PlaceDrawing::ARROWS)&.map { |arrow| arrow.map(&fraction) }
        IR::PlaceDrawing::Stance.new(spot: spot.map(&fraction), arrows: arrows)
      end

      # A number or a value the game works out, as a stance takes.
      def stance_number?(number) = number.is_a?(Numeric) || number.is_a?(DSL::Value)

      def refuse_bad_stance_spot!(verb, name, spot)
        numbers = spot.is_a?(Array) && spot.length == 3 && spot.all? { |n| stance_number?(n) }
        unless numbers
          raise ArgumentError, "#{verb} :#{name} was given at: #{spot.inspect}. at: needs three numbers: across, up " \
                               "and ahead. To fix this, give `at: [x, y, z]`, with numbers or values the game works out."
        end
        return if spot.all? { |n| n.is_a?(DSL::Value) || n.abs <= DSL::Place::FURTHEST }

        raise ArgumentError, "#{verb} :#{name} was given at: #{spot.inspect}. Each number of at: is from " \
                             "-#{DSL::Place::FURTHEST} to #{DSL::Place::FURTHEST}. To fix this, give numbers in that range."
      end

      def refuse_bad_facing!(verb, name, facing)
        arrows = facing.is_a?(Hash) && facing.keys.sort == IR::PlaceDrawing::ARROWS.sort &&
                 facing.values_at(*IR::PlaceDrawing::ARROWS)
        fits = arrows && arrows.all? { |arrow| arrow.is_a?(Array) && arrow.length == 3 && arrow.all? { |n| stance_number?(n) } }
        unless fits
          raise ArgumentError, "#{verb} :#{name} was given facing: #{facing.inspect}. facing: needs three arrows: " \
                               "right:, up: and ahead:, each three numbers. To fix this, give arrows like " \
                               "`facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] }`, or `facing: bot.facing`."
        end
        reason = arrows.flatten.all?(Numeric) && DSL::Viewer.unfit_arrows_reason(arrows)
        return unless reason

        raise ArgumentError, "#{verb} :#{name} was given a facing: that cannot be: #{reason}. Each arrow has a " \
                             "length of one, and each is square to the other two. To fix this, give arrows like " \
                             "right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1]."
      end
    end
  end
end
