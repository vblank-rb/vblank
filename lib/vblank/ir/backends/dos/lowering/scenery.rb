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
          # sprites in front of them all; their cells changed one at a time, held to the frame's end, or a whole
          # other map at once; tiles the game paints from a list; and a background drawn from another list of
          # colours. A background or a stack that needs more is refused by name (PART), until the slice that
          # makes it.
          module Scenery
            STATEMENT_KINDS = %i[background scroll_background set_tile show_held_tiles show_map copy_tiles copy_owed_tiles
                                 background_colors].freeze

            # The kinds that change a background's cells, which the interpreter answers by building the view again
            # every pass (Reference#collect_definitions, @repaints), as it does for a scroll.
            REBUILT_EACH_PASS = %i[scroll_background set_tile show_map tile_run background_colors].freeze

            # The part of the build a game with such a screen waits for, for a test run to count skips by.
            PART = "a screen of tiles with status bars, boxes, bends, turns, other colours, " \
                   "text, or a scene's own scenery; sprites painted from a list"

            # Whether +program+ shows a screen made of tiles.
            def self.tiled?(program) = program.walk.any? { |node| node.kind == :screen && tiles_mode?(node.mode) }

            # Whether +program+ has scenery: a screen made of tiles, or a background stamped onto a painted one,
            # which the interpreter draws into the picture as it draws any (Reference#exec_background).
            def self.used_in?(program) = tiled?(program) || program.walk.any? { |node| node.kind == :background }

            def self.tiles_mode?(mode) = SceneHandover::DISPLAYS.key?(mode) && SceneHandover.tiles?(mode)

            # Every background +program+ declares, numbered by where it is in this list.
            def self.backgrounds_in(program) = Stacking.picture(program).scenery

            def self.reserve(memory, program)
              return unless used_in?(program)

              Runtime::Scenery.reserve(memory, backgrounds_in(program).size, held: holds_cells?(program), runs: paints_tiles?(program))
            end

            # Whether +program+ paints tiles of a background from a list.
            def self.paints_tiles?(program) = program.walk.any? { |node| node.kind == :tile_run && node.picture.nil? }

            def self.holds_cells?(program) = program.walk.any? { |node| node.kind == :set_tile && node.held }

            # Whether +program+'s sprites are drawn into the view at their levels (Runtime::Sprites::LEVELS) rather than
            # over it: a screen of tiles whose layers put a background in front of a sprite, or its sprites at
            # different levels, which a picture drawn over the view in the table's order would not keep.
            def self.stacks_sprites?(program)
              return false unless tiled?(program)

              picture = Stacking.picture(program)
              levels = picture.objects.flat_map { |object| Stacking.levels_of(picture.depths, object) }.uniq
              levels.size > 1 || (levels.any? && Stacking.scenery_over_objects?(picture.depths, scenery: picture.scenery, objects: picture.objects))
            end

            # What Runtime::Scenery.emit is handed: the levels the view is built from, and how many backgrounds there
            # are; nil for a game with no screen of tiles.
            def scenery_plan
              return unless scenery_used?

              { levels: scenery_levels, backgrounds: scenery_backgrounds.size,
                cells: scenery_kinds.include?(:set_tile), held: Scenery.holds_cells?(@program), maps: scenery_kinds.include?(:show_map),
                runs: Scenery.paints_tiles?(@program) }
            end

            private

            def tiled_screen? = @tiled_screen.nil? ? (@tiled_screen = Scenery.tiled?(@program)) : @tiled_screen
            def scenery_used? = @scenery_used.nil? ? (@scenery_used = Scenery.used_in?(@program)) : @scenery_used

            def scenery_backgrounds = (@scenery_backgrounds ||= Scenery.backgrounds_in(@program))

            def stacked_picture = (@stacked_picture ||= Stacking.picture(@program))

            # Whether the picture is built again whenever the sprites are placed, as the interpreter builds it in
            # a game that scrolls (Reference @repaints).
            def scenery_rebuilt_each_pass? = scenery_kinds.intersect?(REBUILT_EACH_PASS)

            def scenery_kinds = (@scenery_kinds ||= @program.walk.to_set(&:kind))

            def refuse_unmade_scenery!
              if @program.walk.any? { |node| node.kind == :tile_run && node.picture }
                raise NotMadeYet.new("This game paints a sprite's picture from a list. The #{CONSOLE.title} build does not " \
                                     "make that yet. To fix this, leave it out for now.", part: PART)
              end
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
              return "a layer that shows through" if @program.walk.any? { |node| node.kind == :layers && !node.see_through.empty? }

              scenery_backgrounds.each do |bg|
                what = unmade_in_background(bg) and return what
              end
              return "text" if tiled_screen? && @program.walk.any? { |node| %i[draw_text draw_digit].include?(node.kind) }
              return "blocks (`pixelate`)" if @program.walk.any? { |node| node.kind == :pixelate }

              nil
            end

            # The view's levels from the back (Runtime::Scenery#emit_view): at each, the places of the records of the
            # backgrounds there, in the order the stack draws them, and whether a sprite drawn into the view can be
            # there.
            def scenery_levels
              depths = stacked_picture.depths
              order = scenery_backgrounds.each_index.sort_by { |number| [depths.of_scenery(scenery_backgrounds[number]), number] }
              by_level = order.group_by { |number| depths.of_scenery(scenery_backgrounds[number]) }
              sprite_levels = sprites_stacked? ? stacked_picture.objects.flat_map { |object| Stacking.levels_of(depths, object) } : []
              (0...depths.count).map do |level|
                [by_level.fetch(level, []).map { |number| @art_places.fetch([:background, number]) }, sprite_levels.include?(level)]
              end
            end

            def sprites_stacked? = @sprites_stacked.nil? ? (@sprites_stacked = Scenery.stacks_sprites?(@program)) : @sprites_stacked

            def unmade_in_background(bg)
              return "a status bar" if bg.bar?
              return "a background shown only above a row" if bg.above_row
              return "a background held to a box" if bg.boxed
              return "a background that turns" if bg.affine
              return "a background drawn from several lists of colours the game changes" if bg.follows_several?
              return "a background drawn in other colours with tiles the game paints" if recolored?(bg) && bg.tiles.any? { |name| painted_tiles.key?(name) }
              return "a background whose tiles come in sets" if bg.several_sets?
              return "a scene's own background" if bg.scene

              nil
            end

            # Every colour a background's tiles draw, and every backdrop a screen shows, for the palette.
            def scenery_colors
              return [] unless scenery_used?

              tiles = scenery_backgrounds.flat_map do |bg|
                [nil, *bg.recolors.to_a.each_index].flat_map do |set|
                  swaps = set && bg.list_swaps(set)
                  bg.tiles.uniq.reject { |name| painted_tiles.key?(name) }.flat_map { |name| tile_colors(name, swaps).compact }
                end
              end
              backdrops = @program.walk.select { |node| node.kind == :screen }.filter_map { |node| @plan.handover.backdrop_of(node) }
              runs = painted_tiles.values.map(&:first).uniq.flat_map { |run| run.colors.drop(1).map { |color| color || 0 } }
              (tiles + backdrops + runs).map { |color| Graphics::Color.resolve(color) }.uniq
            end

            # Each background's tiles, map and record in the art segment.
            def make_scenery_art
              return unless scenery_used?

              @scenery_tile_places = []
              records = scenery_backgrounds.each_with_index.map { |bg, number| scenery_record(bg, number) }
              records.each_with_index do |fields, number|
                @art_places[[:background, number]] = @art.bytesize
                @art << fields.pack("v*").ljust(Runtime::Scenery::RECORD_BYTES, "\0")
              end
              @picks_at = {}.compare_by_identity
              make_run_art
              @program.walk.select { |node| node.kind == :set_tile && node.picked? }.each do |node|
                @picks_at[node] = @art.bytesize
                @art << node.picks.map { |tile| picked_place(tile, @scenery_tile_places.fetch(background_named(node.name))) }.pack("v*")
              end
            end

            # One background's record (Runtime::Scenery::RECORD), its tiles and cells put in the art segment first, and
            # the row lengths of each map, and each map's cells as declared where the game shows another.
            def scenery_record(bg, number)
              places, mixed, mask_delta, block = put_tiles(bg)
              @scenery_tile_places[number] = places
              (@scenery_mask_deltas ||= [])[number] = mask_delta
              (@scenery_color_blocks ||= [])[number] = block
              map = bg.map
              maps = bg.maps.empty? ? [map] : bg.maps
              wraps = !bg.streams?
              grid_cols, grid_rows = TileMap.grid(map) if TileMap.fits?(map)
              cols = wraps ? grid_cols : maps.map { |each| each.map(&:length).max || 0 }.max
              rows = wraps ? grid_rows : maps.map(&:length).max
              cells = put_cells(map, cols, rows, places)
              copies = maps.map do |each|
                lengths = @art.bytesize
                @art << Array.new(rows) { |r| each.fetch(r, []).length }.pack("v*")
                [shows_other_maps?(bg) ? put_map_rows(each, places) : cells, lengths]
              end
              table = @art.bytesize
              @art << copies.flatten.pack("v*")
              wrap_w, wrap_h = wraps ? [grid_cols * bg.tile_w, grid_rows * bg.tile_h] : [0, 0]
              across, down = stamp_repeats(bg, map)
              step_x, step_y = grid_cols ? [grid_cols * bg.tile_w, grid_rows * bg.tile_h] : [0, 0]
              [cells, cols, rows, bg.tile_w, bg.tile_h, wrap_w, wrap_h, wraps ? 1 : 0, across, down, step_x, step_y,
               maps.map(&:length).max * bg.tile_h, Runtime::Scenery.state_at(@memory, number), mixed, mask_delta,
               copies.first.last, table, copies.size, 0]
            end

            # +map+'s cells, +cols+ across and +rows+ down, into the art segment: a word a cell, where its tile's pixels
            # are in +places+, and NO_TILE where the map has none. Answers where they start.
            def put_cells(map, cols, rows, places)
              start = @art.bytesize
              @art << Array.new(rows) do |r|
                Array.new(cols) { |c| (tile = map.fetch(r, [])[c]) ? places.fetch(tile) : Runtime::Scenery::NO_TILE }
              end.flatten.pack("v*")
              start
            end

            # +map+'s own cells into the art segment as declared, each row as long as the map's row and no longer, for
            # rt_scenery_show_map to lay out. Answers where they start.
            def put_map_rows(map, places)
              start = @art.bytesize
              @art << map.flatten.map { |tile| tile ? places.fetch(tile) : Runtime::Scenery::NO_TILE }.pack("v*")
              start
            end

            # Whether the game hands +bg+ another of its maps (Reference#exec_show_map), so each is kept as declared.
            def shows_other_maps?(bg) = bg.maps.size > 1 && @program.walk.any? { |node| node.kind == :show_map && node.name == bg.name }

            # A background's tiles into the art segment as Runtime::Scenery keeps them: the solid ones, then those with
            # see-through pixels, then those ones' masks. Answers where each tile's pixels went (NO_TILE for a tile with
            # nothing but see-through pixels), where the ones with see-through pixels start, and how far each one's
            # mask is from its pixels.
            #
            # A tile a run paints (#painted_tiles) is see-through all over until the game first paints it, and is kept
            # with the ones that have see-through pixels, since any of its pixels can be.
            #
            # A background drawn from other lists of colours has the whole of that kept again for each list, laid out
            # the same, one after the other (Runtime::Scenery::RECORD's +colors_offset+); answers too how long one is.
            def put_tiles(bg)
              blank = Runtime::TRANSPARENT.chr * (bg.tile_w * bg.tile_h)
              painted = bg.tiles.map { |name| painted_tiles.key?(name) }
              pixels = bg.tiles.each_with_index.map { |name, i| painted[i] ? blank : tile_bytes(bg, name) }
              start = @art.bytesize
              places, mixed_start, mask_delta = put_tile_pixels(pixels, painted)
              block = @art.bytesize - start
              bg.recolors.to_a.each_index do |set|
                swaps = bg.list_swaps(set)
                put_tile_pixels(bg.tiles.map { |name| tile_bytes(bg, name, swaps) }, painted)
              end
              [places, mixed_start, mask_delta, block]
            end

            # Tiles' +pixels+ into the art segment: the solid ones, then those with see-through pixels, then those
            # ones' masks; a tile with nothing but see-through pixels is not kept, unless it is +painted+.
            def put_tile_pixels(pixels, painted)
              see_through = pixels.map { |tile| tile.bytes.count(Runtime::TRANSPARENT) }
              shown = pixels.each_index.reject { |i| see_through[i] == pixels[i].bytesize && !painted[i] }
              solid, mixed = shown.partition { |i| see_through[i].zero? }
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

            # Each tile of a background a run paints from a list, by name: the run, and which of its tiles it is.
            def painted_tiles
              @painted_tiles ||= @program.walk.select { |node| node.kind == :tile_run && node.picture.nil? }
                                         .flat_map { |run| run.tiles.each_with_index.map { |name, k| [name, [run, k]] } }.to_h
            end

            # Each run's header and tiles (Runtime::Scenery::RUN_COUNT and the rest) in the art segment, with its
            # colours and where each byte of a tile goes, by run.
            def make_run_art
              runs = painted_tiles.values.map(&:first).uniq
              runs.each do |run|
                side = run.tile_side
                per_row = side / 8
                tile_bytes = run.squares_per_tile * Reference::RUN_TILE_BYTES
                colors = @art.bytesize
                @art << Array.new(16) { |place| place.zero? ? 0 : palette_entry(run.colors[place] || 0) }.pack("C*")
                places = @art.bytesize
                @art << Array.new(tile_bytes) do |byte|
                  square, at = byte.divmod(Reference::RUN_TILE_BYTES)
                  top = (square / per_row * 8) + (at / 4)
                  (top * side) + (square % per_row * 8) + (at % 4 * 2)
                end.pack("v*")
                entries = scenery_backgrounds.each_with_index.flat_map do |bg, number|
                  bg.tiles.each_with_index.filter_map do |name, i|
                    k = run.tiles.index(name) if painted_tiles[name]&.first.equal?(run)
                    k && [[k * tile_bytes, 0x7FFF].min, @scenery_tile_places[number].fetch(i), @scenery_mask_deltas[number]]
                  end
                end
                @art_places[[:run, run.name]] = @art.bytesize
                @art << [entries.size, colors, places, tile_bytes, *entries.flatten].pack("v*")
              end
            end

            # Reference#exec_background_colors: the copy of the tiles in the list of colours numbered +which+ shown from
            # now on, or the colours they were drawn in where it names none of the background's lists.
            def emit_background_colors(node)
              number = background_named(node.name)
              sets = scenery_backgrounds[number].recolors.to_a.size
              drawn = fresh_label("colors_as_drawn")
              chosen = fresh_label("colors_chosen")
              emit_value(node.which)
              @asm.cmp(:eax, sets)
              @asm.jae(drawn) # with no sign: a number below nought names none either
              @asm.inc(:eax)
              @asm.mov(:ecx, @scenery_color_blocks.fetch(number))
              @asm.imul(:eax, :ecx)
              @asm.jmp(chosen)
              @asm.label(drawn)
              @asm.xor(:eax, :eax)
              @asm.label(chosen)
              @asm.push(:ds)
              @asm.mov_segment(:bx, :art)
              @asm.mov(:ds, :bx)
              @asm.mov(X86.mem(nil, @art_places.fetch([:background, number]) + Runtime::Scenery.field(:colors_offset), size: 16), :ax)
              @asm.pop(:ds)
              @asm.call("rt_scenery_rebuild")
            end

            # Reference#exec_copy_tiles
            def emit_copy_tiles(node)
              emit_paint_run(node.name)
              @asm.call("rt_scenery_rebuild") if scenery_used?
            end

            # Reference#exec_copy_owed_tiles: every run whose bit is set in its mask painted, in order.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                skip = fresh_label("run_not_owed")
                @asm.test(number_at(node.masks.fetch(i / per)), 1 << (i % per))
                @asm.je(skip)
                emit_paint_run(name)
                @asm.label(skip)
              end
              @asm.call("rt_scenery_rebuild") if scenery_used?
            end

            # The run +name+ painted, where it paints any background's tiles.
            def emit_paint_run(name)
              header = scenery_used? && @art_places[[:run, name]] or return

              run = painted_tiles.values.map(&:first).find { |each| each.name == name } # the declaration its art was made from
              @asm.mov(:bx, list_place(run.list))
              @asm.mov(:si, header)
              @asm.call("rt_scenery_paint_run")
            end

            # Reference#grid_repeats: how many times the grid is seen across the screen and down it.
            def stamp_repeats(bg, map)
              return [1, 1] if bg.streams? || !TileMap.fits?(map) || bg.tile_w != 8 || bg.tile_h != 8

              cols, rows = TileMap.grid(map)
              [(@memory.screen.width.to_f / (cols * 8)).ceil, (@memory.screen.height.to_f / (rows * 8)).ceil]
            end

            # A tile's pixels as palette entries, TRANSPARENT where it is see-through (Reference#tile_colors).
            def tile_bytes(bg, name, swaps = nil)
              image = picture_image(name)
              unless [image.width, image.height] == [bg.tile_w, bg.tile_h]
                raise LoweringError, "the tile #{name.inspect} of the background #{bg.name.inspect} is not #{bg.tile_w} by #{bg.tile_h}"
              end

              tile_colors(name, swaps).map { |color| color.nil? ? Runtime::TRANSPARENT : palette_entry(color) }.pack("C*")
            end

            # Each pixel's colour of the tile +name+, nil where it is see-through, drawn from the lists +swaps+ gives
            # for the one each of its pixels was drawn from (Reference#tile_colors); in the colours it was drawn in
            # where +swaps+ is nil. A swap goes by a pixel's place, so what is see-through stays so.
            def tile_colors(name, swaps = nil)
              image = picture_image(name)
              swapped = swaps && swaps[image.list_drawn_from]
              recolor = swapped && Assets::Recolor.of(image, swapped)
              Array.new(image.width * image.height) do |at|
                next if image.tile_see_through_at?(at)

                recolor.nil? ? image.color_at(at) : recolor.color_for(at, image.color_at(at))
              end
            end

            def recolored?(bg) = !bg.recolors.to_a.empty?

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
              emit_stamps_in_front(node)
            end

            # A layer can put a background behind one already up, and a stamp covers wherever it has solid pixels,
            # so each background up in front of +node+ is stamped again over it, back to front, which settles the
            # stack (Reference#put_up_background). A game whose backgrounds go up in the order they are drawn
            # stamps nothing more.
            def emit_stamps_in_front(node)
              stack = stacked_picture.stack
              depth = stack.index(node.layer) or return
              in_front = scenery_backgrounds.each_index.select do |number|
                other = stack.index(scenery_backgrounds[number].layer)
                other && other > depth
              end
              in_front.sort_by { |number| [stack.index(scenery_backgrounds[number].layer), number] }.each do |number|
                state = Runtime::Scenery.state_at(@memory, number)
                down = fresh_label("background_not_up")
                @asm.cmp(X86.mem(nil, state + Runtime::Scenery::SHOWN, size: 32), 0)
                @asm.je(down)
                @asm.mov(:si, @art_places.fetch([:background, number]))
                @asm.call("rt_scenery_stamp")
                @asm.label(down)
              end
            end

            # In a list of the tiles a set_tile picks from, a number that names none of the background's tiles.
            PICKS_NOTHING = Runtime::Scenery::NO_TILE - 1

            # Where the pixels of a tile a set_tile can pick are, in the list of them it picks from (#make_scenery_art).
            def picked_place(tile, places) = tile.nil? || tile >= places.size ? PICKS_NOTHING : places.fetch(tile)

            # Reference#exec_set_tile: the tile worked out first, and nothing more where it names none of the
            # background's tiles; then its column and row, and the change made or held.
            def emit_set_tile(node)
              number = background_named(node.name)
              places = @scenery_tile_places.fetch(number)
              done = fresh_label("no_tile_set")
              if node.picked?
                emit_picked_tile(node, done)
              else
                return unless node.tile.nil? || node.tile < places.size

                @asm.mov(:dx, node.tile.nil? ? Runtime::Scenery::NO_TILE : places.fetch(node.tile))
              end
              @asm.push(:dx)
              emit_values_into(%i[eax ecx], [value_node(node.col), value_node(node.row)])
              @asm.pop(:dx)
              @asm.mov(:si, @art_places.fetch([:background, number]))
              @asm.call(node.held ? "rt_scenery_hold_cell" : "rt_scenery_set_cell")
              @asm.label(done)
            end

            # The place of the pixels of the tile +node+ picks by a number the game works out, into DX, from a list of
            # them in the art segment; to +done+ where the number names none (Reference#tile_picked).
            def emit_picked_tile(node, done)
              table = @picks_at.fetch(node)
              emit_value(node.picked_by)
              @asm.sub(:eax, node.picks_from) unless node.picks_from.zero?
              @asm.cmp(:eax, node.picks.size)
              @asm.jae(done) # with no sign: a number below the first is past them too
              @asm.mov(:bx, :ax)
              @asm.add(:bx, :bx)
              @asm.push(:ds)
              @asm.mov_segment(:ax, :art)
              @asm.mov(:ds, :ax)
              @asm.mov(:dx, X86.mem(:bx, table, size: 16))
              @asm.pop(:ds)
              @asm.cmp(:dx, PICKS_NOTHING)
              @asm.je(done)
            end

            def emit_show_held_tiles(_node) = @asm.call("rt_scenery_show_held")

            # Reference#exec_show_map
            def emit_show_map(node)
              emit_value(node.which)
              @asm.mov(:si, @art_places.fetch([:background, background_named(node.name)]))
              @asm.call("rt_scenery_show_map")
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

            # The drawing steps that leave the game's picture as it is: sprites are drawn over a copy of it as a frame
            # is sent, a fade and a tint change the card's colours, a camera where later drawing goes, a list of
            # colours what sprites are drawn in, and a screen of tiles shows its backdrop by building the view.
            LEAVES_PICTURE = %i[present_objects save_region fade tint camera color_list_holds screen].freeze

            # Anything else drawn into the picture: it is no longer the view as last built, so the next build that is
            # owed is made, as the interpreter makes it, over what was drawn (Runtime::Scenery::BUILT).
            def emit_picture_drawn_over(node)
              return unless scenery_used? && node.category == :draw
              return if STATEMENT_KINDS.include?(node.kind) || LEAVES_PICTURE.include?(node.kind)

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
