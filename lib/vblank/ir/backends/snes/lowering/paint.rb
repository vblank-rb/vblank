# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # A PAINTED SCREEN, lowered for a Super Nintendo: each drawing statement a call into
          # Runtime::Paint, and what it paints — its colours, its pictures, its text — made into
          # SNES::PaintedArt while the program is built. Mixed into Lowering.
          #
          # Text and digits are pictures too: the words of a `draw_text` are known when the game is
          # built, so they are drawn once, here, in their font and colour, and painted at run time as
          # any picture is. A digit is one of ten such pictures, picked by the number; text in a
          # colour picked as the game runs is one of two.
          module Paint
            STATEMENTS = Ractor.make_shareable({
                                                 clear_screen: :emit_clear_screen, fill_rect: :emit_fill_rect,
                                                 dma_fill_rect: :emit_fill_rect, draw_rect_at: :emit_fill_rect,
                                                 pixel: :emit_pixel, inside: :emit_inside, blit: :emit_blit,
                                                 blit_pose: :emit_blit_pose, draw_text: :emit_draw_text,
                                                 draw_digit: :emit_draw_digit, save_region: :emit_save_region,
                                                 restore_region: :emit_restore_region, camera: :emit_camera,
                                                 draw_column_at: :emit_draw_column_at
                                               })

            # What a column of a picture is handed over in (#emit_draw_column_at), the height first.
            COLUMN = %i[height slice x top width].freeze

            # What a picture's column holds for a pixel that is see-through (Runtime::Paint).
            SEE_THROUGH = 0xFF

            # The kinds that paint, which make a screen painted when the game names none. The camera
            # only moves the view over what was painted.
            PAINTING = (STATEMENTS.keys - [:camera]).freeze

            # Whether +program+'s screen is painted: it says `screen :bitmap`, or it says no screen and
            # paints. A program can have only one kind (see #refuse_unmade_picture!).
            def self.painted?(program)
              modes = program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              return modes.include?(:bitmap) unless modes.empty?

              program.walk.any? { |node| PAINTING.include?(node.kind) }
            end

            # The SNES::PaintedArt the game paints with.
            attr_reader :painted_art

            def prepare_paint
              @painted = Paint.painted?(@program)
              @painted_art = PaintedArt.new
              @picture_lists = [] # each a list of SNES::PaintedArt pictures' numbers
              @patches = {} # a backing buffer's name -> [its place, its width, its height]
              @column_routines = {} # a picture's name -> the routine that draws a column of it
              @column_tables = {} # a picture's name -> its columns' places
              @inks = [] # each a TextInk, by its number
              @text_inks = {} # a draw_text node's object_id -> its ink's number, or nil for none
            end

            # Whether +program+ paints text in a colour picked as it runs, which an ink can paint
            # (#emit_draw_text): its colours then change as it runs (Runtime::Tint::COLORS_NOW).
            def self.inks?(program)
              painted?(program) && program.walk.any? { |node| node.kind == :draw_text && node.picked }
            end

            def painted? = @painted

            # Does the game draw columns of pictures on the console (Runtime::Paint's
            # rt_paint_column)? Columns drawn in a routine on the Super FX chip are the chip's own
            # (Runtime::ChipColumns).
            def paints_columns?
              return false unless @painted

              on_chip = @chip_routines.flat_map { |name| Reach.statements_under(@funcs.fetch(name)) }.to_h { |node| [node.object_id, true] }
              @reachable.any? { |node| node.kind == :draw_column_at && !on_chip[node.object_id] }
            end

            # The numbers a column is handed over in, kept before any routine is made, since a routine
            # can be lowered more than once.
            def keep_column_numbers
              return unless paints_columns?

              @column_numbers = COLUMN.to_h { |what| [what, keep_local(:"column_#{what}")] }
            end

            # The routine that draws a column of each picture drawn so on the console, and the table of
            # its columns for each picture drawn so on the console or the Super FX chip. The chip's
            # tables are their own: a see-through pixel is place 0 there, and black another place
            # (PaintedArt#place_never_nought).
            def column_sections
              @column_routines.each_key do |name|
                image = Assets::Image.of(picture_named(name))
                @column_tables["column starts of #{name}"] = Array.new(image.width) { |slice| column_places(image, slice) }
              end
              chip_column_pictures.each do |name|
                image = Assets::Image.of(picture_named(name))
                @column_tables[chip_column_starts(name)] = Array.new(image.width) { |slice| chip_column_places(image, slice) }
              end
              @column_routines.map do |name, label|
                image = Assets::Image.of(picture_named(name))
                routine_section(label, [], routine: "#{name.inspect} drawn a column at a time") { emit_column_walk(name, image) }
              end
            end

            # Every backing buffer — the patch of the screen under a sprite on a painted screen — given
            # its room in work RAM.
            def reserve_patches
              @program.walk.select { |node| node.kind == :backing_buffer }.each do |node|
                bytes = Runtime::Paint.patch_bytes(node.width, node.height)
                place = @memory.reserve_far("the patch under #{node.name.inspect}", bytes)
                @patches[node.name] = [place, node.width, node.height]
              end
            end

            # The tables Runtime::Paint reads, as sections for the Linker: the colours, every picture
            # and its rows, and the lists of pictures.
            def paint_sections
              tables = W65816.new("paint tables", holds: Picture::ART)
              tables.label("art colors")
              tables.data_bytes(@painted_art.cgram.bytes)
              tables.label("paint pictures")
              @painted_art.pictures.each do |picture|
                tables.data_longs("paint rows #{picture.number}")
                tables.data_bytes(0)
                tables.data_words(picture.across, picture.height)
              end
              tables.label("paint picture lists")
              @picture_lists.each_index do |number|
                tables.data_longs("paint picture list #{number}")
                tables.data_bytes(0)
              end
              @picture_lists.each_with_index do |numbers, number|
                tables.label("paint picture list #{number}")
                tables.data_words(numbers.length, *numbers)
              end
              # Each ink: its place's byte in the colour list, the colour shown and the colour picked.
              tables.label("paint inks")
              @inks.each { |ink| tables.data_words(ink.ink.place * 2, ink.shown, ink.picked, 0) }
              tables.data_words(0) if @inks.empty?
              @painted_art.pictures.each do |picture|
                tables.label("paint rows #{picture.number}")
                picture.height.times do |row|
                  tables.data_longs("paint row #{picture.number}.#{row}")
                  tables.data_bytes(0)
                end
              end
              [tables.section, *picture_row_sections, *column_table_sections]
            end

            # The most bytes of pictures' rows in one section: well inside a bank of the cartridge.
            ROWS_A_SECTION = 0x6000

            private

            # Each picture's columns, top to bottom, a place to a byte, as many to a section as fit, so
            # a wall of many pictures side by side can be bigger than a bank. Where each column
            # starts is a table of its own, in the part that does not move.
            def column_table_sections
              @column_tables.flat_map do |label, columns|
                starts = W65816.new(label, holds: Picture::ART)
                starts.label(label)
                columns.each_index do |slice|
                  starts.data_longs("#{label}, column #{slice}")
                  starts.data_bytes(0)
                end
                [starts.section, *columns.each_slice(ROWS_A_SECTION / columns.first.length).with_index.map do |part, number|
                  column_bytes_section(label, part, number * (ROWS_A_SECTION / columns.first.length))
                end]
              end
            end

            def column_bytes_section(label, columns, first)
              asm = W65816.new("#{label}, columns from #{first}", holds: Picture::ART)
              columns.each_with_index do |places, number|
                asm.label("#{label}, column #{first + number}")
                asm.data_bytes(places)
              end
              asm.section
            end

            def column_places(image, slice)
              Array.new(image.height) do |row|
                at = (row * image.width) + slice
                image.drawn_at?(at) ? @painted_art.place_of(image.color_at(at)) : SEE_THROUGH
              end
            end

            def chip_column_places(image, slice)
              Array.new(image.height) do |row|
                at = (row * image.width) + slice
                image.drawn_at?(at) ? @painted_art.place_never_nought(image.color_at(at)) : 0
              end
            end

            # Reference#exec_draw_column_at: one column of a picture stretched to a height worked out
            # as the game runs. A height of nought or less draws nothing, and the others are not
            # worked out. The picture's own routine works out where the walk starts, once a
            # column (#emit_column_walk), and the runtime walks it.
            def emit_draw_column_at(node)
              label = @column_routines[node.name] ||= "column of #{node.name}"
              value(node.height)
              store(@column_numbers.fetch(:height))
              done = fresh("no_height")
              jump_unless(Build.binop(:>, Build.var_ref(@column_numbers.fetch(:height)), Build.int(0)), done)
              %i[slice x top].each do |what|
                value(value_node(node.public_send(what)))
                store(@column_numbers.fetch(what))
              end
              load_constant(node.width || 1)
              store(@column_numbers.fetch(:width))
              call_routine(label)
              @asm.label(done)
            end

            # Only the rows on the screen are walked, so a wall nose-to-nose costs what any wall of the
            # screen's height costs. The step down the picture in 65536ths is worked out here, and
            # where it stands at the first row shown.
            def emit_column_walk(name, image)
              height, x, top, width = %i[height x top width].map { |what| Build.var_ref(@column_numbers.fetch(what)) }
              step, first, last, start = %i[step first last start].map { |what| keep_local(what) }
              value(Build.binop(:/, Build.int(image.height << Reference::FIXED), height))
              store(step)
              pointer = keep_local(:pointer)
              value(Build.clamped(Build.var_ref(@column_numbers.fetch(:slice)), Build.int(0), Build.int(image.width - 1)))
              2.times { @asm.asl(@asm.direct(R0)) } # four bytes to a column's start
              @asm.ldx(@asm.direct(R0))
              2.times do |half|
                @asm.lda(@asm.long_x("column starts of #{name}", half * 2))
                @asm.sta(@asm.abs(place_of(pointer), half * 2))
              end
              value(Build.clamped(Build.neg(top), Build.int(0), Build.int(Int32::MAX)))
              store(first)
              value(Build.clamped(height, Build.int(Int32::MIN), Build.binop(:-, Build.int(Runtime::Picture::SCREEN_HEIGHT), top)))
              store(last)
              done = fresh("no_rows")
              jump_unless(Build.binop(:<, Build.var_ref(first), Build.var_ref(last)), done)
              value(Build.binop(:*, Build.var_ref(first), Build.var_ref(step)))
              store(start)
              runtime_call("rt_paint_column", [Build.var_ref(pointer), Build.var_ref(step), Build.var_ref(start),
                                               Build.binop(:-, Build.var_ref(last), Build.var_ref(first)),
                                               x, Build.binop(:+, top, Build.var_ref(first)), width])
              @asm.label(done)
            end

            # Each picture's rows, as many to a section as fit.
            def picture_row_sections
              sections = []
              asm = nil
              bytes = 0
              @painted_art.pictures.each do |picture|
                picture.rows.each_with_index do |row, number|
                  if asm.nil? || bytes + row.bytesize > ROWS_A_SECTION
                    sections << asm.section if asm
                    asm = W65816.new("paint rows #{sections.length}", holds: Picture::ART)
                    bytes = 0
                  end
                  asm.label("paint row #{picture.number}.#{number}")
                  asm.data_bytes(row.bytes)
                  bytes += row.bytesize
                end
              end
              sections << asm.section if asm
              sections
            end

            def value_node(operand) = operand.is_a?(Integer) ? Build.int(operand) : operand

            def place_of_color(color) = @painted_art.place_of(Graphics::Color.resolve(color))

            # Reference#exec_clear_screen.
            def emit_clear_screen(node)
              runtime_call("rt_paint_clear", [Build.int(place_of_color(node.color))])
            end

            # Reference#exec_fill_rect, #exec_dma_fill_rect and #exec_draw_rect_at: the same rectangle.
            def emit_fill_rect(node)
              runtime_call("rt_paint_fill", [*%i[x y w h].map { |edge| value_node(node.public_send(edge)) },
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
              area = @memory[Runtime::Paint::AREA]
              words = Runtime::Paint::AREA_WORDS
              words.times do |i|
                @asm.lda(@asm.abs(area + (i * 2)))
                @asm.pha
              end
              runtime_call("rt_paint_area", %i[x y w h].map { |edge| value_node(node.public_send(edge)) })
              emit_children(node)
              (words - 1).downto(0) do |i|
                @asm.pla
                @asm.sta(@asm.abs(area + (i * 2)))
              end
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
            #
            # TEXT WHOSE COLOUR IS PICKED AS THE GAME RUNS is painted in an INK of its own, where
            # there is a place of the colour list to spare for one: a third picture of the words,
            # painted in the ink's place, whose colour is set as the text is drawn
            # (Runtime::Paint's rt_paint_blit_inked). The ink's pixels are the same whichever colour
            # is picked, so text that changes only its colour paints and sends no tile: the colour
            # list changes, as the console's own games change the colour of their text. Where the
            # ink cannot stand for the colour (see the runtime) the picture in the colour is painted.
            def emit_draw_text(node)
              shown = text_picture(node.text, node.font, node.fonts, node.color)
              unless node.picked
                return runtime_call("rt_paint_blit", [Build.int(shown), value_node(node.x), value_node(node.y)])
              end

              picked = text_picture(node.text, node.font, node.fonts, node.picked)
              showing = Build.binop(:!=, value_node(node.showing), Build.int(0))
              number = text_ink(node)
              unless number
                return runtime_call("rt_paint_blit_one_of", [Build.int(picture_list([shown, picked])), showing,
                                                             value_node(node.x), value_node(node.y)])
              end

              inked = text_picture(node.text, node.font, node.fonts, @inks.fetch(number).ink)
              runtime_call("rt_paint_blit_inked", [Build.int(picture_list([shown, picked, inked])), showing,
                                                   value_node(node.x), value_node(node.y), Build.int(number)])
            end

            # An ink and the two colours its text is drawn in.
            TextInk = Data.define(:ink, :shown, :picked)

            # The number of +node+'s ink, made the first time it is lowered (a routine can be lowered
            # more than once), or nil when there is none. The game's own colours must all fit in the
            # colour list, and they are not all met yet, so an ink takes a place only while more than
            # half the list is free, and a game has MOST_INKS at most.
            def text_ink(node)
              @text_inks.fetch(node.object_id) do
                @text_inks[node.object_id] =
                  if @inks.length < Runtime::Paint::MOST_INKS && @painted_art.places_left > PaintedArt::COLORS / 2
                    shown = Graphics::Color.resolve(node.color)
                    @inks << TextInk.new(ink: @painted_art.ink(shown), shown: shown, picked: Graphics::Color.resolve(node.picked))
                    @inks.length - 1
                  end
              end
            end

            # Reference#exec_draw_digit: one of the ten digits' pictures; a number outside 0 to 9 none.
            def emit_draw_digit(node)
              digits = (0..9).map { |digit| text_picture(digit.to_s, node.font, node.fonts, node.color) }
              runtime_call("rt_paint_blit_one_of", [Build.int(picture_list(digits)), node.value,
                                                    value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_camera: the view moved over the painted picture (Runtime::Paint's
            # rt_paint_camera). A tiled screen's view moves with its background's scroll instead, as
            # on the Advance.
            def emit_camera(node)
              raise LoweringError, CAMERA_ON_TILES unless painted?

              runtime_call("rt_paint_camera", [value_node(node.x), value_node(node.y)])
            end

            CAMERA_ON_TILES = "This game moves the camera on a tiled screen. The camera moves a painted " \
                              "(bitmap) screen only. To move a tiled background, use `scroll_to` or " \
                              "`scroll_by` on the background."

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

            # The number of the picture +name+ declares, made into SNES::PaintedArt's form.
            def picture_number(name)
              @painted_art.picture([:image, name]) do
                image = Assets::Image.of(picture_named(name))
                drawn = {}
                (image.width * image.height).times do |at|
                  drawn[[at % image.width, at / image.width]] = image.color_at(at) if image.drawn_at?(at)
                end
                [image.width, image.height, drawn]
              end.number
            end

            # The number of the picture of +text+ in +font+ and +color+.
            def text_picture(text, font, fonts, color)
              resolved = color.is_a?(PaintedArt::Ink) ? color : Graphics::Color.resolve(color)
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
