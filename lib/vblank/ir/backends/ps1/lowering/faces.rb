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
          # face, which Runtime::Faces does as the interpreter does. Mixed into Lowering.
          #
          # Each picture a face can show is a record (Runtime::Faces's RECORD_ fields) and its pixels,
          # made while the program is built; a face's list of pictures is a table of their records.
          module Faces
            STATEMENTS = Ractor.make_shareable({ draw_place: :emit_children, fill_face: :emit_fill_face })

            # The part of the build a lit face waits on (Lowering#refuse_unmade_parts!).
            LIT_FACES = "faces lit by a shading"

            # Whether the game fills a face anywhere, so its build carries Runtime::Faces. Known once
            # Lowering#sections has made every routine, since a picture is registered as its fill is made.
            def fills_faces? = face_pictures.any?

            # The pictures' records and pixels, and each list of pictures, as sections for the Linker.
            def face_sections
              return [] unless fills_faces?

              tables = R3000.new("face pictures", holds: TABLES_HOLDING)
              pixels = face_pictures.map do |name, label|
                image = @cache.image(picture_named(name))
                tables.label(label)
                tables.data_words("#{label} pixels", image.width.bit_length - 1, image.width - 1, image.height - 1)
                face_pixels_section("#{label} pixels", image)
              end
              face_picture_lists.each do |names, label|
                tables.label(label)
                tables.data_words(names.map { |name| face_pictures.fetch(name) })
              end
              [tables.section, *pixels]
            end

            private

            # Each picture a face can show, by name, and the label of its record.
            def face_pictures = (@face_pictures ||= {})

            # Each list of pictures a face picks from, by the names, and the label of its table.
            def face_picture_lists = (@face_picture_lists ||= {})

            # Reference#exec_fill_face, in its order: the picture's number held to the ends of the list,
            # then the count, then the corners read from the list (Runtime::Faces's rt_face_corners); a
            # face of fewer than three corners stops there, as the interpreter's does, and only then are
            # its edges and perspective worked out and the face filled.
            def emit_fill_face(node)
              node.pictures.each { |name| register_face_picture(name) }
              table = face_picture_lists[node.pictures] ||= "face picture list #{face_picture_lists.length}"
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
              call_routine("rt_fill_face")
              @asm.label(too_few)
            end

            # The picture +name+ a face shows, given a record once.
            def register_face_picture(name)
              face_pictures[name] ||= begin
                image = @cache.image(picture_named(name))
                unless [image.width, image.height].all? { |side| side.positive? && (side & (side - 1)).zero? }
                  raise LoweringError, "The picture #{name.inspect} is on the face of a place, and its sides are " \
                                       "#{image.width} and #{image.height} pixels. A face's picture must have sides " \
                                       "of 1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels. To fix this, make the picture one of those sizes."
                end
                "face picture #{face_pictures.length}"
              end
            end

            # A picture's pixels as Runtime::Faces reads them: a halfword each, row by row, the colour with
            # its top bit set, or nought where the picture is see-through.
            def face_pixels_section(label, image)
              asm = R3000.new(label, holds: TABLES_HOLDING)
              asm.label(label)
              asm.data_halves(Array.new(image.width * image.height) do |at|
                TextureMemory.texel_for_color(image.drawn_at?(at) ? image.color_at(at) : nil)
              end)
              asm.align
              asm.section
            end
          end
        end
      end
    end
  end
end
