# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        class Lowering
          # A SCREEN MADE OF TILES, laid out for the runtime to draw (Runtime::Scenery, which says how the picture
          # is built). Mixed into Lowering.
          #
          # Each background is given a number, in the order the stack lists them (IR::Stacking.picture), its
          # tiles and its map are put in the art segment with its record, and the view is built from the records
          # in the order the interpreter paints them: by their level in the stack, and in that order inside one.
          #
          # WHAT IS MADE SO FAR is backgrounds every screen shows, put up and scrolled, over a backdrop, with
          # sprites in front of them all. A background or a stack that needs more is refused by name (PART), as
          # is every step that changes a background's cells or how it is shown, until the slice that makes it.
          module Scenery
            STATEMENT_KINDS = %i[background scroll_background].freeze

            # The part of the build a game with such a screen waits for, for a test run to count skips by.
            PART = "a screen of tiles with layers over sprites, status bars, boxes, bends, turns, other colours, " \
                   "text, or a scene's own scenery"

            # Whether +program+ shows a screen made of tiles.
            def self.tiled?(program) = program.walk.any? { |node| node.kind == :screen && tiles_mode?(node.mode) }

            # Whether +program+ has scenery: a screen made of tiles, or a background stamped onto a painted one,
            # which the interpreter draws into the picture as it draws any (Reference#exec_background).
            def self.used_in?(program) = tiled?(program) || program.walk.any? { |node| node.kind == :background }

            def self.tiles_mode?(mode) = SceneHandover::DISPLAYS.key?(mode) && SceneHandover.tiles?(mode)

            # Every background +program+ declares, numbered by where it is in this list.
            def self.backgrounds_in(program) = Stacking.picture(program).scenery

            def self.reserve(memory, program)
              Runtime::Scenery.reserve(memory, backgrounds_in(program).size) if used_in?(program)
            end

            # What Runtime::Scenery.emit is handed: the art segment's place of the list the view is built in
            # the order of, and how many backgrounds there are; nil for a game with no screen of tiles.
            def scenery_plan
              return unless scenery_used?

              { order: @art_places.fetch(:scenery_order), backgrounds: scenery_backgrounds.size }
            end

            private

            def tiled_screen? = @tiled_screen.nil? ? (@tiled_screen = Scenery.tiled?(@program)) : @tiled_screen
            def scenery_used? = @scenery_used.nil? ? (@scenery_used = Scenery.used_in?(@program)) : @scenery_used

            def scenery_backgrounds = (@scenery_backgrounds ||= Scenery.backgrounds_in(@program))

            def stacked_picture = (@stacked_picture ||= Stacking.picture(@program))

            # Whether the picture is built again whenever the sprites are placed, as the interpreter builds it in
            # a game that scrolls (Reference @repaints).
            def scenery_rebuilt_each_pass? = @program.walk.any? { |node| node.kind == :scroll_background }

            def refuse_unmade_scenery!
              return unless scenery_used?

              what = unmade_in_scenery or return
              raise NotMadeYet.new("This game shows a screen of tiles with #{what}. The #{CONSOLE.title} build does not " \
                                   "make that yet. To fix this, leave it out for now.", part: PART)
            end

            # What about the game's screen of tiles the build does not make yet, in words, or nil.
            def unmade_in_scenery
              screens = @program.walk.select { |node| node.kind == :screen }
              return "a screen that turns" if screens.any? { |node| node.mode == :rotozoom }
              return "a painted screen as well" if screens.map { |node| Scenery.tiles_mode?(node.mode) }.uniq.size > 1
              return "a screen of its own in a scene" unless @plan.handover.scene_screens.empty?
              return "a backdrop that follows a list of colours" if @plan.handover.backdrop_follows_list?
              return "layers that put a background in front of a sprite" if scenery_over_sprites?
              return "a layer that shows through" if @program.walk.any? { |node| node.kind == :layers && !node.see_through.empty? }

              scenery_backgrounds.each do |bg|
                what = unmade_in_background(bg) and return what
              end
              return "text" if tiled_screen? && @program.walk.any? { |node| %i[draw_text draw_digit].include?(node.kind) }
              return "blocks (`pixelate`)" if @program.walk.any? { |node| node.kind == :pixelate }

              nil
            end

            def scenery_over_sprites?
              Stacking.scenery_over_objects?(stacked_picture.depths, scenery: stacked_picture.scenery, objects: stacked_picture.objects)
            end

            def unmade_in_background(bg)
              return "a status bar" if bg.bar?
              return "a background shown only above a row" if bg.above_row
              return "a background held to a box" if bg.boxed
              return "a background that turns" if bg.affine
              return "a background drawn in other colours" unless bg.recolors.to_a.empty? && bg.follows.nil?
              return "a background whose tiles come in sets" if bg.several_sets?
              return "a scene's own background" if bg.scene
              return "a background in a named layer" if bg.layer && stacked_picture.stack.include?(bg.layer)

              nil
            end

            # Every colour a background's tiles draw, and every backdrop a screen shows, for the palette.
            def scenery_colors
              return [] unless scenery_used?

              tiles = scenery_backgrounds.flat_map(&:tiles).uniq.flat_map do |name|
                image = picture_image(name)
                (0...(image.width * image.height)).reject { |at| image.tile_see_through_at?(at) }.map { |at| image.color_at(at) }
              end
              backdrops = @program.walk.select { |node| node.kind == :screen }.filter_map { |node| @plan.handover.backdrop_of(node) }
              (tiles + backdrops).map { |color| Graphics::Color.resolve(color) }.uniq
            end

            # Each background's tiles, map and record in the art segment, and the list the view is built in the
            # order of.
            def make_scenery_art
              return unless scenery_used?

              records = scenery_backgrounds.each_with_index.map { |bg, number| scenery_record(bg, number) }
              records.each_with_index do |fields, number|
                @art_places[[:background, number]] = @art.bytesize
                @art << fields.pack("v*").ljust(Runtime::Scenery::RECORD_BYTES, "\0")
              end
              order = scenery_backgrounds.each_index.sort_by { |number| [stacked_picture.depths.of_scenery(scenery_backgrounds[number]), number] }
              @art_places[:scenery_order] = @art.bytesize
              @art << [order.size, *order.map { |number| @art_places.fetch([:background, number]) }].pack("v*")
            end

            # One background's record (Runtime::Scenery::RECORD), its tiles and map put in the art segment first.
            def scenery_record(bg, number)
              places, mixed, mask_delta = put_tiles(bg)
              map = bg.map
              wraps = !bg.streams?
              grid_cols, grid_rows = TileMap.grid(map) if TileMap.fits?(map)
              cols = wraps ? grid_cols : (map.map(&:length).max || 0)
              rows = wraps ? grid_rows : map.length
              cells = @art.bytesize
              @art << Array.new(rows) do |r|
                Array.new(cols) { |c| (tile = map.fetch(r, [])[c]) ? places.fetch(tile) : Runtime::Scenery::NO_TILE }
              end.flatten.pack("v*")
              wrap_w, wrap_h = wraps ? [grid_cols * bg.tile_w, grid_rows * bg.tile_h] : [0, 0]
              across, down = stamp_repeats(bg, map)
              step_x, step_y = grid_cols ? [grid_cols * bg.tile_w, grid_rows * bg.tile_h] : [0, 0]
              [cells, cols, rows, bg.tile_w, bg.tile_h, wrap_w, wrap_h, wraps ? 1 : 0, across, down, step_x, step_y,
               map.length * bg.tile_h, Runtime::Scenery.state_at(@memory, number), mixed, mask_delta]
            end

            # A background's tiles into the art segment as Runtime::Scenery keeps them: the solid ones, then those with
            # see-through pixels, then those ones' masks. Answers where each tile's pixels went (NO_TILE for a tile with
            # nothing but see-through pixels), where the ones with see-through pixels start, and how far each one's
            # mask is from its pixels.
            def put_tiles(bg)
              pixels = bg.tiles.map { |name| tile_bytes(bg, name) }
              see_through = pixels.map { |tile| tile.bytes.count(Runtime::TRANSPARENT) }
              solid, mixed = pixels.each_index.reject { |i| see_through[i] == pixels[i].bytesize }.partition { |i| see_through[i].zero? }
              places = Array.new(pixels.size, Runtime::Scenery::NO_TILE)
              solid.each do |i|
                places[i] = @art.bytesize
                @art << pixels[i]
              end
              mixed_start = @art.bytesize
              mixed.each do |i|
                places[i] = @art.bytesize
                @art << pixels[i].tr("\xFF".b, "\0")
              end
              mask_delta = @art.bytesize - mixed_start
              mixed.each { |i| @art << pixels[i].bytes.map { |byte| byte == Runtime::TRANSPARENT ? 0xFF : 0 }.pack("C*") }
              [places, mixed_start, mask_delta]
            end

            # Reference#grid_repeats: how many times the grid is seen across the screen and down it.
            def stamp_repeats(bg, map)
              return [1, 1] if bg.streams? || !TileMap.fits?(map) || bg.tile_w != 8 || bg.tile_h != 8

              cols, rows = TileMap.grid(map)
              [(@memory.screen.width.to_f / (cols * 8)).ceil, (@memory.screen.height.to_f / (rows * 8)).ceil]
            end

            # A tile's pixels as palette entries, TRANSPARENT where it is see-through (Reference#tile_colors).
            def tile_bytes(bg, name)
              image = picture_image(name)
              unless [image.width, image.height] == [bg.tile_w, bg.tile_h]
                raise LoweringError, "the tile #{name.inspect} of the background #{bg.name.inspect} is not #{bg.tile_w} by #{bg.tile_h}"
              end

              (0...(image.width * image.height)).map do |at|
                image.tile_see_through_at?(at) ? Runtime::TRANSPARENT : palette_entry(image.color_at(at))
              end.pack("C*")
            end

            def background_number(node)
              scenery_backgrounds.index { |bg| bg.equal?(node) } or raise LoweringError, "the background #{node.name.inspect} is not in the stack"
            end

            # The background a line naming +name+ means: the one declaration of it, since a scene's own is refused.
            def background_named(name)
              scenery_backgrounds.index { |bg| bg.name == name } or raise LoweringError, "the background #{name.inspect} is never declared"
            end

            # Reference#exec_background: what is owed painted first, then the background put up.
            def emit_background(node)
              number = background_number(node)
              @asm.call("rt_scenery_paint_owed")
              @asm.mov(:si, @art_places.fetch([:background, number]))
              @asm.mov(:bx, Runtime::Scenery.state_at(@memory, number))
              @asm.call("rt_scenery_put_up")
            end

            # Reference#exec_scroll_background
            def emit_scroll_background(node)
              emit_values_into(%i[eax ecx], [value_node(node.x), value_node(node.y)])
              @asm.mov(:bx, Runtime::Scenery.state_at(@memory, background_named(node.name)))
              @asm.call("rt_scenery_scroll")
            end

            # Reference#exec_screen, on a screen of tiles: the backdrop it means shown, where it means one.
            def emit_tiled_screen(node)
              color = @plan.handover.backdrop_of(node) or return

              @asm.mov(:al, palette_entry(color))
              @asm.call("rt_scenery_backdrop")
            end

            # Anything else drawn into the picture: it is no longer the view as last built, so the next build that is
            # owed is made, as the interpreter makes it, over what was drawn (Runtime::Scenery::BUILT).
            def emit_picture_drawn_over(node)
              return unless scenery_used? && node.category == :draw && !STATEMENT_KINDS.include?(node.kind)

              @asm.mov(runtime_at(Runtime::Scenery::BUILT), 0)
            end

            # Reference#exec: an owed view built before any step that does not leave it owed.
            def emit_owed_scenery_paint(node)
              return unless scenery_used?
              return if Reference.defers_repaint?(node)

              done = fresh_label("view_not_owed")
              @asm.cmp(runtime_at(Runtime::Scenery::OWED), 0)
              @asm.je(done)
              @asm.call("rt_scenery_paint_owed")
              @asm.label(done)
            end

            # Reference#exec_in_loop: a write the end of a pass places, run with that said.
            def with_pass_end_placing(node)
              placed = scenery_used? && placed_at_pass_end.include?(node)
              @asm.mov(runtime_at(Runtime::Scenery::PLACING), 1) if placed
              yield
              @asm.mov(runtime_at(Runtime::Scenery::PLACING), 0) if placed
            end

            def placed_at_pass_end
              @placed_at_pass_end ||= game_loops.flat_map { |loop| console_loop(loop).placed }.to_set.compare_by_identity
            end
          end
        end
      end
    end
  end
end
