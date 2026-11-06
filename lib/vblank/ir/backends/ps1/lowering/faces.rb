# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # THE FACES OF A PLACE, lowered for a PlayStation. Drawing a place is the statements under it
          # (IR::PlaceDrawing): turning each point to the viewer, cutting at the near limit and finding
          # where it lands are sums every lowering makes, so they come out the interpreter's to the bit,
          # and `screen_spot`, which runs the same sums, agrees with them. What is left is filling each
          # face, which the graphics chip does (Runtime::Faces). Mixed into Lowering.
          #
          # Each picture a face can show is a texture in video RAM (PS1::TextureMemory), placed so the
          # chip's texture window repeats it, and a record (Runtime::Faces's RECORD_ fields) made once the
          # textures have their places; a face's list of pictures is a table of their records.
          module Faces
            STATEMENTS = Ractor.make_shareable({ draw_place: :emit_children, fill_face: :emit_fill_face })

            # The least side the chip's texture window repeats: a picture narrower or shorter than this is
            # kept repeated out to it.
            LEAST_WINDOW_TEXELS = 8

            # Whether the game fills a face anywhere, so its build carries Runtime::Faces. Known once
            # Lowering#sections has made every routine, since a picture is registered as its fill is made.
            def fills_faces? = face_pictures.any?

            # The pictures' records and each list of pictures, as a section for the Linker. Made after the
            # textures have their places (#paint_sections).
            def face_sections
              return [] unless fills_faces?

              tables = R3000.new("face pictures", holds: TABLES_HOLDING)
              face_pictures.each_value do |picture|
                tables.label(picture.label)
                tables.data_words(*face_record(picture))
              end
              face_picture_lists.each do |(names, shading), label|
                tables.label(label)
                tables.data_words(names.map { |name| face_pictures.fetch([name, shading]).label })
              end
              [tables.section]
            end

            private

            # THE LIST A PLACE'S DRAWING HANDS EACH FACE'S CORNERS IN, kept in the scratchpad where the runtime
            # reads a face's corners (Runtime::Faces::CORNERS_LIST_OFFSET_BYTES), or nil for none. The drawing
            # puts every corner of every face drawn there, and the fill reads them all back: in main RAM, which
            # has no cache, each number written and read again waits on the bus, and the fill copied every
            # corner's six into the scratchpad first. Kept there, they are written and read in the scratchpad
            # and copied not at all. A list is kept there only where it is the one list every fill is handed,
            # of words and no longer than a face's corners: rt_face_corners copies any other list's corners
            # into those slots, which would change the kept list under the game. A game drawing two places
            # hands two lists, so keeps neither there. Nor is a list the game takes items from the front of,
            # since rt_face_corners reads such a list's items one by one into those same slots.
            def corners_list_in_face
              return @corners_list_in_face if defined?(@corners_list_in_face)

              room = Nodes::FillFace::MOST_CORNERS * Nodes::FillFace::CORNER_NUMBERS
              handed = @program.walk.select { |node| node.kind == :fill_face }.map(&:corners).uniq
              name = handed.first if handed.length == 1
              list = name && @declared_lists[name]
              fits = list && LoweringPlan::SLOT_BYTES.fetch(list.width) == 4 && list.capacity <= room &&
                     !@lists_dropped_from_front.include?(name)
              @corners_list_in_face = fits ? name : nil
            end

            # A picture a face shows, as faces lit by one shading (or by none, +shading+ nil) show it: its
            # record's label, its size, and its texture.
            FacePicture = Data.define(:label, :width, :height, :texture, :shading)

            # Each picture a face can show, by [name, the name of the shading it is lit by or nil].
            def face_pictures = (@face_pictures ||= {})

            # Each picture's texture, by name, whichever shadings light it.
            def face_textures = (@face_textures ||= {})

            # Each list of pictures a face picks from, by [the names, the shading], and the label of its table.
            def face_picture_lists = (@face_picture_lists ||= {})

            # Reference#exec_fill_face, in its order: the picture's number held to the ends of the list,
            # then the count, then the corners read from the list (Runtime::Faces's rt_face_corners); a
            # face of fewer than three corners stops there, as the interpreter's does, and only then are
            # its edges and perspective worked out and the face filled. A lit face's records name its
            # shading's colour tables, and the face is told how many levels the shading has.
            def emit_fill_face(node)
              shading = node.shading && shading_named(node.shading)
              node.pictures.each { |name| register_face_picture(name, shading) }
              table = face_picture_lists[[node.pictures, node.shading]] ||= "face picture list #{face_picture_lists.length}"
              face = runtime_place(Runtime::Faces::FACE)
              emit_value(Build.clamped(node.picture, Build.int(0), Build.int(node.pictures.length - 1)))
              @asm.sll(:v0, :v0, 2)
              @asm.la(:t0, table)
              @asm.addu(:t0, :t0, :v0)
              @asm.lw(:v0, 0, :t0)
              emit_store_word(:v0, face + Runtime::Faces::PICTURE_OFFSET_BYTES)
              corners = @lists.fetch(node.corners) { raise LoweringError, "the list #{node.corners.inspect} is used and never declared" }
              runtime_call("rt_face_corners", [Build.int(corners.address), node.count])
              too_few = fresh_label("face_too_few")
              emit_load_word(:t0, face + Runtime::Faces::COUNT_OFFSET_BYTES)
              @asm.slti(:t0, :t0, 3)
              @asm.bne(:t0, :zero, too_few)
              [[node.left, Runtime::Faces::LEFT_OFFSET_BYTES], [node.top, Runtime::Faces::TOP_OFFSET_BYTES], [node.right, Runtime::Faces::RIGHT_OFFSET_BYTES],
               [node.bottom, Runtime::Faces::BOTTOM_OFFSET_BYTES], [node.perspective, Runtime::Faces::SPANS_OFFSET_BYTES]].each do |value, at|
                emit_value(value)
                emit_store_word(:v0, face + at)
              end
              @asm.li(:v0, shading ? FacePieces.light_floor(shading.levels.length) : 0)
              emit_store_word(:v0, face + Runtime::Faces::LIGHT_FLOOR_OFFSET_BYTES)
              call_routine("rt_fill_face")
              @asm.label(too_few)
            end

            # The game's shading named +name+ (Nodes::Shading).
            def shading_named(name)
              @shadings_by_name ||= @program.walk.select { |node| node.kind == :shading }.to_h { |node| [node.name, node] }
              @shadings_by_name.fetch(name) { raise LoweringError, "the shading #{name.inspect} is used and never declared" }
            end

            # The picture +name+ a face shows lit by +shading+ (a Nodes::Shading, or nil), its record made
            # once. The chip shades a lit face's texels itself (Runtime::Faces), so lit or not the texture and
            # its colour table are the picture's own.
            def register_face_picture(name, shading)
              face_pictures[[name, shading&.name]] ||= begin
                texture = register_face_texture(name)
                image = @cache.image(picture_named(name))
                FacePicture.new(label: "face picture #{face_pictures.length}", width: image.width, height: image.height,
                                texture: texture, shading: shading&.name)
              end
            end

            # The picture +name+ a face shows, made a texture once. Its sides are powers of two, so the
            # texture window can repeat it; one under LEAST_WINDOW_TEXELS a side is repeated out to that in
            # the texture, which shows the same texel at every place.
            def register_face_texture(name)
              face_textures[name] ||= begin
                image = @cache.image(picture_named(name))
                unless [image.width, image.height].all? { |side| side.positive? && (side & (side - 1)).zero? && side <= TextureMemory::PAGE_TEXELS }
                  raise LoweringError, "The picture #{name.inspect} is on the face of a place, and its sides are " \
                                       "#{image.width} and #{image.height} pixels. A face's picture must have sides " \
                                       "of 1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels. To fix this, make the picture one of those sizes."
                end
                across = [image.width, LEAST_WINDOW_TEXELS].max
                down = [image.height, LEAST_WINDOW_TEXELS].max
                colors = Array.new(across * down) do |at|
                  place = ((at / across % image.height) * image.width) + (at % across % image.width)
                  image.drawn_at?(place) ? image.color_at(place) : nil
                end
                texture_memory.add_texture(width: across, height: down, colors: colors, align: true)
              end
            end

            # A picture's record (Runtime::Faces's RECORD_ fields): its texture window, its colour table and
            # page as a triangle's corners carry them, and its size as masks.
            def face_record(picture)
              h = Console::PS1Hardware
              texture = picture.texture
              u = texture.u_at(texture.x)
              v = texture.y % TextureMemory::PAGE_TEXELS
              window = h::GP0_TEXTURE_WINDOW | window_mask(texture.width) | (window_mask(texture.height) << 5) |
                       ((u >> 3) << 10) | ((v >> 3) << 15)
              table = texture.table ? texture.table.field : 0
              page = texture.draw_mode & 0x1FF
              [window, table << 16, page << 16, -picture.width & 0xFFFF_FFFF, -picture.height & 0xFFFF_FFFF]
            end

            # The texture window's mask for a side of +texels+: which of u's bits (in eights) are replaced
            # by where the texture starts, so u repeats every +texels+.
            def window_mask(texels) = ((TextureMemory::PAGE_TEXELS - texels) >> 3) & 0x1F
          end
        end
      end
    end
  end
end
