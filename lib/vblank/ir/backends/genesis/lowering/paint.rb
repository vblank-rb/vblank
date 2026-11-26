# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # A painted screen, lowered for a Genesis: each drawing statement a call into Runtime::Paint,
          # and what it paints — its colours, its pictures, its text — made into Genesis::PaintedArt
          # while the program is built. Mixed into Lowering.
          #
          # Text and digits are pictures too: the words of a `draw_text` are known when the game is
          # built, so they are drawn once, here, in their font and colour, and painted at run time as
          # any picture is. A digit is one of ten such pictures, picked by the number; text in a
          # colour picked as the game runs is one of two.
          module Paint
            STATEMENT_KINDS = %i[
              clear_screen fill_rect draw_rect_at pixel inside blit blit_pose draw_text
              draw_digit save_region restore_region camera draw_column_at
            ].freeze

            # What a column of a picture is handed over in (#emit_draw_column_at), and what its walk
            # works out as it goes (#emit_column_walk): the walk's slice is the one handed over, clamped.
            COLUMN = %i[height slice x top width].freeze
            COLUMN_WALK = %i[step row last pixel].freeze

            def emit_paint_statement(node)
              case node.kind
              when :clear_screen then emit_clear_screen(node)
              when :fill_rect then emit_fill_rect(node)
              when :draw_rect_at then emit_fill_rect(node)
              when :pixel then emit_pixel(node)
              when :inside then emit_inside(node)
              when :blit then emit_blit(node)
              when :blit_pose then emit_blit_pose(node)
              when :draw_text then emit_draw_text(node)
              when :draw_digit then emit_draw_digit(node)
              when :save_region then emit_save_region(node)
              when :restore_region then emit_restore_region(node)
              when :camera then emit_camera(node)
              when :draw_column_at then emit_draw_column_at(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether +program+'s screen is painted: it names `screen :bitmap`, or it names no screen and
            # paints (any of STATEMENT_KINDS).
            def self.painted?(program)
              modes = program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              return modes.include?(:bitmap) unless modes.empty?

              program.walk.any? { |node| STATEMENT_KINDS.include?(node.kind) }
            end

            # The Genesis::PaintedArt the game paints with.
            attr_reader :painted_art

            def prepare_paint
              @painted = Paint.painted?(@program)
              @painted_art = PaintedArt.new(exact: self.class.fading?(@program))
              @picture_lists = [] # each a list of PaintedArt pictures' numbers
              @patches = {} # a backing buffer's name -> [its place, its width, its height]
              @column_routines = {} # a picture drawn a column at a time -> its routine's label
            end

            def painted? = @painted

            # Whether the game moves the window over its picture, which is when its cartridge carries the
            # routines that do (Runtime::Paint.emit_camera).
            def camera? = painted? && @program.walk.any? { |node| node.kind == :camera }

            # Reference#exec_camera: the window's corner. A tiled screen has no one picture to move it over
            # (its planes scroll and its sprites sit over them), which is refused where the picture is.
            def emit_camera(node) = runtime_call("rt_camera_to", [node.x, node.y])

            # Every backing buffer — the patch of the screen under a sprite on a painted screen — given
            # its room in work RAM, a byte a pixel.
            def reserve_patches
              @program.walk.select { |node| node.kind == :backing_buffer }.each do |node|
                place = @memory.reserve("the patch under #{node.name.inspect}", node.width * node.height)
                @patches[node.name] = [place, node.width, node.height]
              end
            end

            # The tables Runtime::Paint reads, as sections for the Linker: the colours, every picture
            # and the lists of pictures, the patches kept, and each picture's pixels.
            def paint_sections
              tables = M68000.new("paint tables", holds: DATA)
              tables.label("paint colors")
              tables.data_words(@painted_art.colors_as_words)
              if painted? && self.class.changing_colors?(@program)
                # The picture's palette, then the sprites' three when it shows sprites over it.
                sprites = sprites_over_picture?
                tables.label("colors15")
                tables.data_words(@painted_art.colors_as_15bit +
                                  (sprites ? @art.colors15.drop(Art::PLACES) : Array.new(Art::PLACES * (Art::PALETTES - 1), 0)))
                tables.data_words([@painted_art.colors_painted - 1, *(sprites ? @art.colors_used.drop(1) : [0, 0, 0])])
              end
              tables.label("paint pictures")
              @painted_art.pictures.each do |picture|
                tables.data_longs("paint pixels #{picture.number}")
                tables.data_words(picture.width, picture.height)
              end
              tables.label("paint picture lists")
              @picture_lists.each_index { |number| tables.data_longs("paint picture list #{number}") }
              @picture_lists.each_with_index do |numbers, number|
                tables.label("paint picture list #{number}")
                tables.data_words(numbers.length, *numbers)
              end
              tables.label("paint patches")
              @patches.each_value { |place, width, height| tables.data_longs(place, width * height) }
              tables.data_longs(0)
              [tables.section, *picture_pixel_sections]
            end

            # The routine that draws a column of each picture drawn so (#emit_draw_column_at), made after the
            # program is lowered, which is what says which pictures are drawn so.
            def column_sections
              @column_routines.map do |name, label|
                routine_section(label, [], routine: "#{name.inspect} drawn a column at a time") { emit_column_walk(name) }
              end
            end

            private

            # The numbers a column is handed over in, and the walk's, kept once before any routine is made: a
            # routine can be lowered more than once (#routines_fitting), and a number kept inside it would
            # take memory each time.
            def keep_column_numbers
              return unless @program.walk.any? { |node| node.kind == :draw_column_at }

              @column_numbers = (COLUMN + COLUMN_WALK).to_h { |what| [what, keep_local(:"column_#{what}")] }
              @column_routines = {}
            end

            # Each picture's pixels, a section each.
            def picture_pixel_sections
              @painted_art.pictures.map do |picture|
                asm = M68000.new("paint pixels #{picture.number}", holds: DATA)
                asm.label("paint pixels #{picture.number}")
                asm.data_bytes(picture.pixels)
                asm.section
              end
            end

            def value_node(operand) = operand.is_a?(Integer) ? Build.int(operand) : operand

            def place_of_color(color) = @painted_art.place_of(Graphics::Color.resolve(color))

            # Reference#exec_clear_screen.
            def emit_clear_screen(node)
              runtime_call("rt_paint_clear", [Build.int(place_of_color(node.color))])
            end

            # Reference#exec_fill_rect and #exec_draw_rect_at: the same rectangle.
            def emit_fill_rect(node)
              runtime_call("rt_paint_fill", [*[node.x, node.y, node.w, node.h].map { |edge| value_node(edge) },
                                             Build.int(place_of_color(node.color))])
            end

            # Reference#exec_pixel: a rectangle one pixel square.
            def emit_pixel(node)
              runtime_call("rt_paint_fill", [value_node(node.x), value_node(node.y), Build.int(1), Build.int(1),
                                             Build.int(place_of_color(node.color))])
            end

            # Reference#exec_inside: painting held to the rectangle while the children run, and the
            # area there was before given back after, from the stack — so an `inside` in a routine
            # called from inside another's hands the caller's area back.
            def emit_inside(node)
              @asm.move(:l, runtime_at(Runtime::Paint::AREA), @asm.pre(M68000::SP))
              @asm.move(:l, runtime_at(Runtime::Paint::AREA, 4), @asm.pre(M68000::SP))
              runtime_call("rt_paint_area", [node.x, node.y, node.w, node.h].map { |edge| value_node(edge) })
              emit_children(node)
              @asm.move(:l, @asm.post(M68000::SP), runtime_at(Runtime::Paint::AREA, 4))
              @asm.move(:l, @asm.post(M68000::SP), runtime_at(Runtime::Paint::AREA))
            end

            # Reference#exec_blit.
            def emit_blit(node)
              runtime_call("rt_paint_blit", [Build.int(picture_number(node.name)), value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_blit_pose: one of the poses, by the number the game works out.
            def emit_blit_pose(node)
              list = picture_list(node.poses.map { |name| picture_number(name) })
              runtime_call("rt_paint_blit_one_of", [Build.int(list), node.index, value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_draw_text: the words as a picture in their colour — or, with a colour
            # picked while the game runs, one of two pictures, the picked one when +showing+ is not
            # nought.
            def emit_draw_text(node)
              shown = text_picture(node.text, node.font, node.fonts, node.color)
              unless node.picked
                return runtime_call("rt_paint_blit", [Build.int(shown), value_node(node.x), value_node(node.y)])
              end

              picked = text_picture(node.text, node.font, node.fonts, node.picked)
              runtime_call("rt_paint_blit_one_of", [Build.int(picture_list([shown, picked])),
                                                    Build.binop(:!=, value_node(node.showing), Build.int(0)),
                                                    value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_draw_digit: one of the ten digits' pictures; a number outside 0 to 9 none.
            def emit_draw_digit(node)
              digits = (0..9).map { |digit| text_picture(digit.to_s, node.font, node.fonts, node.color) }
              runtime_call("rt_paint_blit_one_of", [Build.int(picture_list(digits)), node.value,
                                                    value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_draw_column_at: one column of a picture stretched to a height worked out as the
            # game runs. What is drawn is handed over in numbers the program keeps once (COLUMN), the height
            # first: a height of nought or less draws nothing, and the others are not worked out. The picture's
            # own routine walks it (#column_sections).
            def emit_draw_column_at(node)
              numbers = @column_numbers
              label = @column_routines[node.name] ||= "column of #{node.name}"
              value(value_node(node.height))
              store(numbers.fetch(:height))
              done = fresh("column_done")
              jump_unless(Build.binop(:>, Build.var_ref(numbers.fetch(:height)), Build.int(0)), done)
              [[node.slice, :slice], [node.x, :x], [node.top, :top]].each do |part, what|
                value(value_node(part))
                store(numbers.fetch(what))
              end
              load_constant(node.width || 1)
              store(numbers.fetch(:width))
              call_routine(label)
              @asm.label(done)
            end

            # The walk of Reference#exec_draw_column_at: down the screen a row at a time, only the rows that show.
            # Each row is the picture's row the step in 65536ths lands it on, painted across the strip's width by
            # one call into rt_paint_fill, a see-through one left as it was. How much that costs on the console
            # has not been measured against a console game that draws walls a column at a time.
            def emit_column_walk(name)
              numbers = @column_numbers
              ref = ->(what) { Build.var_ref(numbers.fetch(what)) }
              number = picture_number(name)
              image = @cache.image(picture_named(name))
              fixed = Build.int(Reference::FIXED)
              value(Build.clamped(ref.(:slice), Build.int(0), Build.int(image.width - 1)))
              store(numbers.fetch(:slice))
              value(Build.binop(:/, Build.int(image.height << Reference::FIXED), ref.(:height)))
              store(numbers.fetch(:step))
              value(Build.clamped(Build.neg(ref.(:top)), Build.int(0), Build.int(Int32::MAX)))
              store(numbers.fetch(:row))
              value(Build.clamped(ref.(:height), Build.int(Int32::MIN), Build.binop(:-, Build.int(Runtime::Paint::HEIGHT), ref.(:top))))
              store(numbers.fetch(:last))
              walk = fresh("column_row")
              done = fresh("column_done")
              see_through = fresh("column_see_through")
              @asm.label(walk)
              jump_unless(Build.binop(:<, ref.(:row), ref.(:last)), done)
              source = Build.clamped(Build.binop(:>>, Build.binop(:*, ref.(:row), ref.(:step)), fixed),
                                     Build.int(0), Build.int(image.height - 1))
              value(Build.binop(:+, Build.binop(:*, source, Build.int(image.width)), ref.(:slice)))
              @asm.lea(@asm.abs_l("paint pixels #{number}"), @asm.a(0))
              emit_table_entry(1, false, :l)
              store(numbers.fetch(:pixel))
              jump_unless(Build.binop(:!=, ref.(:pixel), Build.int(Runtime::Paint::NOT_DRAWN)), see_through)
              runtime_call("rt_paint_fill", [ref.(:x), Build.binop(:+, ref.(:top), ref.(:row)), ref.(:width), Build.int(1), ref.(:pixel)])
              @asm.label(see_through)
              value(Build.binop(:+, ref.(:row), Build.int(1)))
              store(numbers.fetch(:row))
              jump(walk)
              @asm.label(done)
            end

            # Reference#exec_save_region and #exec_restore_region.
            def emit_save_region(node) = emit_patch("rt_paint_save", node)
            def emit_restore_region(node) = emit_patch("rt_paint_restore", node)

            def emit_patch(routine, node)
              place, width, height = @patches.fetch(node.buffer) do
                raise LoweringError, "the backing buffer #{node.buffer.inspect} is used and never declared"
              end
              runtime_call(routine, [Build.int(place), value_node(node.x), value_node(node.y), Build.int(width),
                                     Build.int(height)])
            end

            # The number of the picture +name+ declares, made into PaintedArt's form.
            def picture_number(name)
              @painted_art.picture([:image, name]) do
                image = @cache.image(picture_named(name))
                drawn = {}
                (image.width * image.height).times do |at|
                  drawn[[at % image.width, at / image.width]] = image.color_at(at) if image.drawn_at?(at)
                end
                [image.width, image.height, drawn]
              end.number
            end

            # The number of the picture of +text+ in +font+ and +color+.
            def text_picture(text, font, fonts, color)
              resolved = Graphics::Color.resolve(color)
              @painted_art.picture([:text, text, font, resolved]) do
                drawn = {}
                fonts.get(font).each_pixel(text) { |x, y| drawn[[x, y]] = resolved }
                width = (drawn.keys.map(&:first).max || 0) + 1
                height = (drawn.keys.map(&:last).max || 0) + 1
                [width, height, drawn]
              end.number
            end

            # The number of the list of pictures +numbers+, made once.
            def picture_list(numbers)
              @picture_lists.index(numbers) || (@picture_lists << numbers).length - 1
            end
          end
        end
      end
    end
  end
end
