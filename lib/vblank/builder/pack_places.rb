# frozen_string_literal: true

module VBlank
  class Builder
    # A 3D PLACE READ FROM THE DATA PACK: a port whose original keeps its levels as data (Descent's
    # mines: corners, rooms' sides, each side's pictures, where each corner falls on them and its
    # light) reads the level from the player's copy, as it reads the copy's pictures and colours.
    # So the place (`place`), the shading it is lit by (`shading`) and where the viewer starts
    # (`viewer`) each take slots of the pack in place of Ruby data. A concern of {Builder}.
    #
    #   pack = data_pack from: ORIGINAL, version: "1" do |slots|
    #     slots.numbers :points, count: 2800 * 3, width: :word, signed: true     # the most the original has
    #     slots.numbers :faces,  count: 9600 * 17, width: :word, signed: true
    #     slots.numbers :sizes,  count: 1, width: :word, signed: true            # how many faces are used
    #     slots.colors  :palette, count: 256, layout: :gba
    #     slots.numbers :fades,  count: 32 * 256, width: :byte, signed: false
    #     slots.numbers :start,  count: 12, width: :word, signed: true
    #     slots.fill_from_copy { |copy, pack| ... }                              # the port's own reading
    #   end
    #   shading :fade, colors: pack[:palette], levels: pack[:fades]
    #   place :mine, points: pack[:points], faces: pack[:faces], faces_used: pack[:sizes].number(0),
    #                pictures: %i[rock moss lava], shading: :fade
    #   eye = viewer :eye, at: pack[:start].as_numbers(at: 0, count: 3, width: :word, signed: true),
    #                      facing: pack[:start].as_numbers(at: 12, count: 9, width: :word, signed: true)
    #
    # WHERE THE DATA LIVES. A place is already drawn from two tables, its points and its faces
    # (Builder::Places#declare_place_data; IR::PlaceDrawing reads them as the game runs and works
    # nothing out from them as it is built). So a place from the pack is those two tables read from
    # slots, by `table`'s own reading of a slot (Builder#table): all-in-one the build reads the slot,
    # and with the pack left out the table holds none of its numbers and every runtime fills it from
    # the file as the game starts (Builder::DataPacks#table_from_pack_slot, IR::StartFile). The
    # unpacking routine writes each record in VBlank's own layout, as it writes a song's notes
    # (Original::PackNote): a point is three words, x, y and z; a face is IR::PlaceDrawing::FACE_STRIDE
    # words, the number of its picture among `pictures:`, then for each of four corners its point's
    # number, where it falls on the picture across and down, and its light from 0 to 1; a face of
    # three corners gives its third twice. Every number but a point's or a picture's is a fraction
    # with sixteen bits (65536 is one), which is how Descent's own `fix` numbers are kept. The
    # pictures are the game's own `image`s, which may themselves be pixels of the pack
    # (`places: pack[:walls].pixels(...)`), so this adds nothing for them: `pictures:` lists the
    # most the level can show, and a face picks one by number.
    #
    # HOW A COUNT LIMITS WHAT IS DRAWN. The game gives the shape and the most there can be: the
    # slots' sizes, the original's limits (MAX_VERTICES, MAX_SEGMENTS times six sides of up to two
    # faces). The pack says what is there: `faces_used:` names one number of the pack, read into a
    # table of one entry, and a drawing draws that many faces, held to 0 and the most, as it starts
    # (IR::PlaceDrawing#face_count). Left out, every face of the slot is drawn. A face numbered past
    # the count is passed over in a list of faces too. The drawing's lists are sized by the most,
    # so a point past those used is never read unless a face names it.
    #
    # NOTHING THE PACK HOLDS STOPS THE GAME. The numbers are the player's, so the drawing holds each
    # point number and picture number a face names to those the place has (IR::PlaceDrawing,
    # +numbers_held+), the fill holds a light to 0..1 as it always does, and a shading's place past
    # its colours is place 0. Built all-in-one, the same tables are drawn the same way, so the two
    # builds draw alike; nothing is checked as the game is built beyond the slots' shapes. A point
    # past -8191..8191 draws bent, as written in Ruby it would be refused.
    #
    # THE SHADING keeps its colours and levels in a node of its own (IR::Nodes::Shading). All-in-one
    # the build reads both slots and the shading is the one the game would write. With the pack left
    # out it holds zeros of their number and where they are in the file (IR::StartFile::Shading):
    # the interpreter reads them as it starts (StartFile.fill_shading), and the C, JavaScript and Ruby
    # runtimes fill the array each lit fill hands them (Computer::StartFileFills
    # #record_start_file_shading_fill, rg_start_file_fill_colors and rg_start_file_fill_places).
    #
    # THE VIEWER'S START is a table of three numbers (at:) and one of nine (facing:), read as any
    # slot of numbers is, and the viewer's variables are set from them where the viewer is declared.
    #
    # EACH CONSOLE'S CARTRIDGE. A cartridge holds its data, so it is always built all-in-one (a
    # cartridge told to leave its pack out is refused at `data_pack`): the place is the same two
    # tables, and the Advance and the PlayStation draw it as they draw any place. The Color, the
    # Super Nintendo and the Genesis refuse `draw_place` as they always do.
    #
    # NOT OFFERED: a place from the pack drawn where the game puts it (`draw_place ..., at:,
    # facing:`), whose test of being in view needs the points while the game is built; and a picture
    # given as numbers into a shading from the pack (`image ..., shading:`), whose colours the build
    # does not hold. Each is refused in plain words.
    module PackPlaces
      private

      # Whether +points+ and +faces+ are slots of the pack: both, or neither, and `faces_used:` only
      # with them.
      def pack_place_given?(points, faces, faces_used)
        handles = [points, faces].count { |given| given.is_a?(DSL::PackSlot) }
        refuse_place_half_from_pack! if handles == 1
        refuse_faces_used_without_pack! if handles.zero? && !faces_used.nil?
        handles == 2
      end

      def refuse_place_half_from_pack!
        raise ArgumentError, "place was given points: and faces: of two kinds: one is a slot of the data pack and one is " \
                             "not. To fix this, give both from the data pack, or both as lists."
      end

      def refuse_faces_used_without_pack!
        raise ArgumentError, "place was given faces_used:, and its points: and faces: are not slots of the data pack. " \
                             "faces_used: says how many faces of a data pack slot are used. To fix this, remove faces_used:."
      end

      # THE PLACE'S POINTS AND FACES AS TABLES READ FROM +points+ AND +faces+ (slots of the pack),
      # and the count of faces used from +faces_used+ (a DSL::PackNumber, or nil for all of them).
      def declare_place_from_pack(shape, points, faces, faces_used)
        most_points = pack_place_records(shape.name, points, "points:", IR::PlaceDrawing::POINT_STRIDE)
        most_faces = pack_place_records(shape.name, faces, "faces:", IR::PlaceDrawing::FACE_STRIDE)
        refuse_pack_place_without_pictures!(shape)
        table(IR::PlaceDrawing.name_of(shape.name, :points), points)
        table(IR::PlaceDrawing.name_of(shape.name, :faces), faces)
        used = (pack_number_table(IR::PlaceDrawing.name_of(shape.name, :faces_used), faces_used, "place :#{shape.name}'s faces_used:") if faces_used)
        shape.declare_from_pack(most_points: most_points, most_faces: most_faces, faces_used_table: used)
        declare_place_lists(shape)
      end

      # How many records of +stride+ words the slot +handle+ holds, or a friendly error naming +key+.
      def pack_place_records(name, handle, key, stride)
        where = "place :#{name}'s #{key}"
        refuse_slot_from_elsewhere!(handle, where)
        refuse_slot_read_wrongly!(handle, :numbers, where)
        fits = handle.layout.width == :word && handle.layout.signed && (handle.count % stride).zero?
        return handle.count / stride if fits

        raise ArgumentError, "#{where} was given slot :#{handle.layout.name}. It must be a slot of numbers " \
                             "`width: :word, signed: true`, #{stride} numbers for each one. To fix this, make the slot " \
                             "like that, with a count that is a multiple of #{stride}."
      end

      def refuse_pack_place_without_pictures!(shape)
        return unless shape.listed_pictures.empty?

        raise ArgumentError, "place :#{shape.name} reads its faces from the data pack, and it lists no pictures. A face " \
                             "names its picture by its number in pictures:. To fix this, give pictures: %i[...], the " \
                             "pictures in the order the faces number them."
      end

      # A TABLE OF ONE ENTRY, number +number+ (a DSL::PackNumber) of its slot, read as the slot is:
      # by the build all-in-one, from the file with the pack left out. +where+ names the line.
      def pack_number_table(name, number, where)
        unless number.is_a?(DSL::PackNumber)
          raise ArgumentError, "#{where} was given #{number.inspect}. It must be one number of the data pack. To fix " \
                               "this, give it like `pack[:sizes].number(0)`."
        end

        slot = number.slot
        refuse_slot_from_elsewhere!(slot, where)
        refuse_slot_read_wrongly!(slot, :numbers, where)
        layout = slot.layout
        if pack_left_out?
          at = @pack_slot_starts.fetch(layout.name) + (number.index * layout.item_bytes)
          return table_from_start_file(name, DSL::StartFileEntries.new(at: at, count: 1, format: layout.format),
                                       width: layout.width, signed: layout.signed).name
        end

        table(name, [pack_slot_values(slot, :numbers, where).fetch(number.index)], width: layout.width, signed: layout.signed).name
      end

      def refuse_pack_place_moved!(verb, shape)
        return unless shape.from_pack?

        raise ArgumentError, "#{verb} :#{shape.name} was given at: or facing:, and the place reads its points from the " \
                             "data pack. The build must know the points to move a place. To fix this, draw the place " \
                             "where it is, without at: and facing:."
      end

      # Whether +colors+ and +levels+ are slots of the pack: both, or neither.
      def pack_shading_given?(name, colors, levels)
        handles = [colors, levels].count { |given| given.is_a?(DSL::PackSlot) }
        if handles == 1
          raise ArgumentError, "shading :#{name} was given colors: and levels: of two kinds: one is a slot of the data " \
                               "pack and one is not. To fix this, give both from the data pack, or both as lists."
        end

        handles == 2
      end

      # THE SHADING FROM +colors+ (a slot of colours, or a bank of one) AND +levels+ (a slot of
      # bytes, each level's places in turn, darkest first): the node `shading` records.
      def pack_shading(name, colors, levels)
        colors_where = "shading :#{name}'s colors:"
        levels_where = "shading :#{name}'s levels:"
        refuse_slot_from_elsewhere!(colors, colors_where)
        refuse_slot_read_wrongly!(colors, :colors, colors_where)
        refuse_slot_from_elsewhere!(levels, levels_where)
        refuse_slot_read_wrongly!(levels, :numbers, levels_where)
        count = colors.count
        refuse_unfit_pack_levels!(name, levels, count)
        level_count = levels.count / count
        if pack_left_out?
          node = Build.shading(name, Array.new(count, 0), Array.new(level_count) { Array.new(count, 0) })
          node.from_file = IR::StartFile::Shading.new(colors_at: colors_in_pack(colors), color_format: colors.layout.format,
                                                      levels_at: @pack_slot_starts.fetch(levels.layout.name))
          return node
        end

        values = pack_slot_values(colors, :colors, colors_where).map { |color| Graphics::Color.resolve(color) }
        places = pack_slot_values(levels, :numbers, levels_where).each_slice(count).to_a
        refuse_bad_levels!(name, values, places)
        Build.shading(name, values, places)
      end

      def refuse_unfit_pack_levels!(name, levels, count)
        fits = levels.layout.width == :byte && !levels.layout.signed && levels.count.positive? && (levels.count % count).zero?
        return if fits

        raise ArgumentError, "shading :#{name}'s levels: was given slot :#{levels.layout.name}. It must be a slot of " \
                             "numbers `width: :byte, signed: false`, #{count} numbers for each level, one for each color. " \
                             "To fix this, make the slot like that, with a count that is a multiple of #{count}."
      end

      # WHERE A VIEWER STARTS, FROM THE PACK: +at+ a handle on three numbers, +facing+ a handle on
      # nine, each nil where the game writes it.
      ViewerStart = Data.define(:at, :facing)

      def viewer_start_in_pack(name, at, facing)
        ViewerStart.new(at: (viewer_start_handle(name, at, "at:", 3) if at.is_a?(DSL::PackSlot)),
                        facing: (viewer_start_handle(name, facing, "facing:", 9) if facing.is_a?(DSL::PackSlot)))
      end

      def viewer_start_handle(name, handle, key, count)
        where = "viewer :#{name}'s #{key}"
        refuse_slot_from_elsewhere!(handle, where)
        refuse_slot_read_wrongly!(handle, :numbers, where)
        return handle if handle.layout.width == :word && handle.layout.signed && handle.count == count

        raise ArgumentError, "#{where} was given slot :#{handle.layout.name}. It must be #{count} numbers " \
                             "`width: :word, signed: true`, each a fraction with sixteen bits (65536 is one). To fix " \
                             "this, give a slot of #{count} such numbers, or a view of them with `as_numbers`."
      end

      # The viewer +seen+'s spot and arrows set from the tables its +start+ (a ViewerStart) reads,
      # where the viewer is declared. Its variables are fractions of sixteen bits, as the numbers are.
      def emit_viewer_start_from_pack(seen, start)
        [[start.at, seen.variables.first(3), :start_at], [start.facing, seen.variables.drop(3), :start_facing]].each do |handle, variables, part|
          next unless handle

          numbers = Messages::MadeNames.make(:viewer_part, viewer: seen.name, part: part)
          table(numbers, handle)
          variables.each_with_index { |variable, k| record(Build.set(variable, Build.table_get(numbers, k))) }
        end
      end
    end
  end
end
