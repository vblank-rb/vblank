# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # A PAINTED SCREEN, lowered for a PlayStation: each drawing statement a call into Runtime::Paint,
          # and what it draws with — its pictures, its text — made into PS1::PaintedArt while the program
          # is built. Mixed into Lowering.
          #
          # Text and digits are pictures too: the words of a `draw_text` are known when the game is built,
          # so they are drawn once, here, in their font and colour, and drawn at run time as any picture
          # is. A digit is one of ten such pictures, picked by the number; text in a colour picked as the
          # game runs is one of two.
          module Paint
            STATEMENT_KINDS = %i[
              screen clear_screen fill_rect dma_fill_rect draw_rect_at pixel inside blit blit_pose draw_text
              draw_digit save_region restore_region
            ].freeze

            def emit_paint_statement(node)
              case node.kind
              when :screen then emit_screen(node)
              when :clear_screen then emit_clear_screen(node)
              when :fill_rect then emit_fill_rect(node)
              when :dma_fill_rect then emit_fill_rect(node)
              when :draw_rect_at then emit_fill_rect(node)
              when :pixel then emit_pixel(node)
              when :inside then emit_inside(node)
              when :blit then emit_blit(node)
              when :blit_pose then emit_blit_pose(node)
              when :draw_text then emit_draw_text(node)
              when :draw_digit then emit_draw_digit(node)
              when :save_region then emit_save_region(node)
              when :restore_region then emit_restore_region(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Reference#exec_save_region: the screen under a sprite, saved into its patch (Runtime::Paint's
            # rt_paint_save).
            def emit_save_region(node)
              patch = patch_for(node.buffer)
              runtime_call("rt_paint_save", [build_value_node(node.x), build_value_node(node.y), Build.int(patch.state),
                                             Build.int(patch.corner), Build.int(patch.width), Build.int(patch.height)])
            end

            # Reference#exec_restore_region: the patch put back.
            def emit_restore_region(node)
              patch = patch_for(node.buffer)
              runtime_call("rt_paint_restore", [build_value_node(node.x), build_value_node(node.y), Build.int(patch.state),
                                                Build.int(patch.corner)])
            end

            # A PATCH: where its state is in RAM (Runtime::Paint::PATCH_STATE_BYTES), where it is in video RAM
            # (y << 16 | x), and its size.
            Patch = Data.define(:state, :corner, :width, :height)

            # The patch the backing buffer +name+ declares, given its places the first time it is asked for:
            # its state in RAM, and its rectangle in video RAM, in a block of columns kept for patches
            # (TextureMemory#reserve_columns), under the one before it while the block has room down and is
            # wide enough, and in a new block as wide as it otherwise.
            def patch_for(name)
              @patches ||= {}
              @patches[name] ||= begin
                node = @program.walk.find { |found| found.kind == :backing_buffer && found.name == name } or
                  raise LoweringError, "the patch #{name.inspect} is used and never declared"
                block_x, block_width, line = @patch_block
                unless @patch_block && node.width <= block_width && line + node.height <= Console::PS1Hardware::VRAM_HEIGHT
                  block_width = node.width
                  block_x = texture_memory.reserve_columns(block_width)
                  line = 0
                end
                @patch_block = [block_x, block_width, line + node.height]
                state = @memory.reserve("the patch under #{name.inspect}", Runtime::Paint::PATCH_STATE_BYTES)
                Patch.new(state: state, corner: (line << 16) | block_x, width: node.width, height: node.height)
              end
            end

            # The PS1::TextureMemory every texture the game draws is kept in.
            def texture_memory = (@texture_memory ||= TextureMemory.new)

            # The PS1::PaintedArt the game draws with.
            def painted_art = (@painted_art ||= PaintedArt.new(texture_memory))

            # The tables Runtime::Paint reads, as sections for the Linker: every picture's pieces, the lists
            # of pictures a number picks from, what is copied into video RAM at power-on (every texture and
            # colour table), and their halfwords. Made last, once every texture has been asked for.
            def paint_sections
              texture_memory.allocate!
              tables = R3000.new("paint tables", holds: TABLES_HOLDING)
              painted_art.pictures.each do |picture|
                tables.label(picture.label)
                tables.data_words(picture.pieces.length)
                picture.pieces.each do |piece|
                  tables.data_halves(piece.dx, piece.dy, piece.width, piece.height)
                  tables.data_words(piece.texture.draw_mode, piece.texture.texture_corner)
                end
              end
              picture_list_labels.each do |labels, list|
                tables.label(list)
                tables.data_words(labels.length, *labels)
              end
              tables.label("paint uploads")
              copies = texture_memory.uploads.each_with_index.map do |upload, number|
                tables.data_words((upload.y << 16) | upload.x, (upload.height << 16) | upload.width, "paint texels #{number}",
                                  upload.words.length)
                build_texel_section("paint texels #{number}", upload.words)
              end
              tables.data_words(0)
              [tables.section, *copies]
            end

            private

            def build_texel_section(label, words)
              asm = R3000.new(label, holds: TABLES_HOLDING)
              asm.label(label)
              asm.data_words(words)
              asm.section
            end

            # Each list of pictures a number picks from, by the pictures' labels, and its own label.
            def picture_list_labels = (@picture_list_labels ||= {})

            # Registers the list of the pictures +labels+ (once), and returns where it is.
            def register_picture_list(labels) = LabelAddress.new(picture_list_labels[labels] ||= "paint picture list #{picture_list_labels.length}")

            def build_value_node(operand) = operand.is_a?(Integer) ? Build.int(operand) : operand

            # The rectangle command in +color+, its 15 bits in the top of each of the command's bytes.
            def rectangle_command(color)
              Build.int(Console::PS1Hardware::GP0_RECTANGLE | Console::PS1Hardware.command_color(Graphics::Color.resolve(color)))
            end

            # Reference#exec_screen: a painted screen of one page or two. Any other kind of screen is
            # refused before anything is made (#refuse_unmade_parts!) in a game that paints, and shows
            # nothing in one that does not.
            def emit_screen(node)
              return unless node.mode == :bitmap

              tear_free = node.buffered && CONSOLE.painted_pages == 2
              runtime_call("rt_paint_screen", [Build.int(tear_free ? 1 : 0)])
            end

            # Reference#exec_clear_screen: the whole area drawing is held to, the whole screen outside any.
            def emit_clear_screen(node) = runtime_call("rt_paint_clear", [rectangle_command(node.color)])

            # Reference#exec_fill_rect, #exec_dma_fill_rect and #exec_draw_rect_at: the same rectangle.
            def emit_fill_rect(node)
              runtime_call("rt_paint_fill", [*[node.x, node.y, node.w, node.h].map { |edge| build_value_node(edge) },
                                             rectangle_command(node.color)])
            end

            # Reference#exec_pixel: a rectangle one pixel square.
            def emit_pixel(node)
              runtime_call("rt_paint_fill", [build_value_node(node.x), build_value_node(node.y), Build.int(1), Build.int(1),
                                             rectangle_command(node.color)])
            end

            # Reference#exec_inside: drawing held to the rectangle while the children run, and the area
            # there was before given back after, from the stack, so an `inside` in a routine called from
            # inside another's hands the caller's area back.
            def emit_inside(node)
              area = runtime_place(Runtime::Paint::AREA)
              4.times do |i|
                emit_load_word(:t0, area + (i * 4))
                emit_push(:t0)
              end
              runtime_call("rt_paint_area", [node.x, node.y, node.w, node.h].map { |edge| build_value_node(edge) })
              emit_children(node)
              3.downto(0) do |i|
                emit_pop(:t0)
                emit_store_word(:t0, area + (i * 4))
              end
            end

            # Reference#exec_blit.
            def emit_blit(node)
              runtime_call("rt_paint_blit", [register_image_picture(node.name), build_value_node(node.x), build_value_node(node.y)])
            end

            # Reference#exec_blit_pose: one of the poses, by the number the game works out.
            def emit_blit_pose(node)
              list = register_picture_list(node.poses.map { |name| register_image_picture(name).label })
              runtime_call("rt_paint_blit_one_of", [list, node.index, build_value_node(node.x), build_value_node(node.y)])
            end

            # Reference#exec_draw_text: the words as a picture in their colour, or, with a colour picked
            # while the game runs, one of two pictures, the picked one when +showing+ is not nought.
            def emit_draw_text(node)
              shown = register_text_picture(node.text, node.font, node.fonts, node.color)
              return runtime_call("rt_paint_blit", [shown, build_value_node(node.x), build_value_node(node.y)]) unless node.picked

              picked = register_text_picture(node.text, node.font, node.fonts, node.picked)
              runtime_call("rt_paint_blit_one_of", [register_picture_list([shown.label, picked.label]),
                                                    Build.binop(:!=, build_value_node(node.showing), Build.int(0)),
                                                    build_value_node(node.x), build_value_node(node.y)])
            end

            # Reference#exec_draw_digit: one of the ten digits' pictures; a number outside 0 to 9 none.
            def emit_draw_digit(node)
              digits = (0..9).map { |digit| register_text_picture(digit.to_s, node.font, node.fonts, node.color).label }
              runtime_call("rt_paint_blit_one_of", [register_picture_list(digits), node.value, build_value_node(node.x), build_value_node(node.y)])
            end

            # The picture +name+ declares (Reference#blit_image: a pixel the picture leaves see-through is
            # not drawn).
            def register_image_picture(name)
              LabelAddress.new(painted_art.register_picture([:image, name]) do
                image = @cache.image(picture_named(name))
                drawn = {}
                (image.width * image.height).times do |at|
                  drawn[[at % image.width, at / image.width]] = image.color_at(at) if image.drawn_at?(at)
                end
                drawn
              end)
            end

            # The picture of +text+ in +font+ and +color+ (Reference#exec_draw_text).
            def register_text_picture(text, font, fonts, color)
              resolved = Graphics::Color.resolve(color)
              LabelAddress.new(painted_art.register_picture([:text, text, font, resolved]) do
                drawn = {}
                fonts.get(font).each_pixel(text) { |x, y| drawn[[x, y]] = resolved }
                drawn
              end)
            end

            def picture_named(name)
              @pictures_declared ||= @program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
              @pictures_declared.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
            end
          end
        end
      end
    end
  end
end
