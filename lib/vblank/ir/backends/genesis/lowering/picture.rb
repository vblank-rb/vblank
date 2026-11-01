# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # THE PICTURE OF A TILED SCREEN, lowered for a Genesis: the statements that draw, as calls
          # into Runtime::Picture, and the game's pictures made into tiles, palettes and maps (Genesis::Art)
          # while the program is built. Mixed into Lowering.
          #
          # A TILED SCREEN. Each background the game declares is given one of the console's two planes, the
          # one declared last in front (plane A), as the interpreter paints the one declared last over the
          # rest. Each map it can show is made into a grid of cells, kept whole in the cartridge and
          # copied onto its plane when it is put up. Each sprite is made of the console's 8×8 sprite
          # pieces, placed in the sprite table every pass the game places its sprites.
          module Picture
            STATEMENTS = Ractor.make_shareable({
                                                 background: :emit_background,
                                                 scroll_background: :emit_scroll_background,
                                                 set_tile: :emit_set_tile, show_map: :emit_show_map,
                                                 present_objects: :emit_present_objects,
                                                 color_list_holds: :emit_color_list_holds,
                                                 background_colors: :emit_background_colors,
                                                 fade: :emit_fade, tint: :emit_tint,
                                                 hide_sprites: :emit_hide_sprites
                                               })

            # The Genesis::Art the game's pictures were made into.
            attr_reader :art

            # The sprite table has this many rows (Console::Description#sprites).
            MOST_SPRITES = Console::GENESIS.sprites

            # The two planes a background can be on: plane A is in front.
            PLANES = 2

            def prepare_picture
              @art = Art.new(backdrop: IR::SceneHandover.of(@program).game_backdrop, exact: self.class.fading?(@program))
              @objects = by_kind(:object)
              @backgrounds = @program.walk.select { |node| node.kind == :background }
              @sprite_names = SpriteNames.new(@program)
              @grids = {}
              @pose_tables = {}
              @layers = {}.compare_by_identity
            end

            # Whether the game draws from tiles: it has a background or a sprite.
            def tiled? = self.class.picture_of(@program) == :tiled

            # How the picture is laid out for the runtime: the plane's columns and rows of cells, which
            # every background of the game shares.
            def plane_size = @plane_size || [32, 32]

            # Each piece of the picture this lowering does not make yet, refused by name: the build
            # makes a tiled screen of 8×8 tiles, at most two backgrounds of one size that every
            # screen shows, and plain sprites in front of them, or a painted screen with nothing
            # drawn from tiles over it.
            def refuse_unmade_picture!
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              others = screens - %i[tiled bitmap]
              refuse_unmade!("a `screen :#{others.first}`") unless others.empty?
              refuse_unmade!("both a painted (bitmap) screen and a tiled one") if screens.include?(:tiled) && painted?
              if painted?
                refuse_unmade!("a background on a painted (bitmap) screen") unless @backgrounds.empty?
                refuse_unmade!("a hardware sprite on a painted (bitmap) screen") unless @objects.empty?
              end
              refuse_unmade!("a camera on a tiled screen") if !painted? && @program.walk.any? { |node| node.kind == :camera }
              refuse_backdrops_of_its_own!
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            # A `screen` other than the game's own that says a backdrop the game's does not: a scene's
            # own. Colour 0 is the console's one backdrop, set once for the game, so one that changes
            # as a scene comes up is not made yet.
            def refuse_backdrops_of_its_own!
              game_backdrop = IR::SceneHandover.of(@program).game_backdrop
              return unless @program.walk.any? { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }

              refuse_unmade!("a scene that says a backdrop of its own (`screen ... backdrop:`)")
            end

            # Reference#exec_fade, which on a console that cannot blend walks the colours (IR::Fading): the
            # whole screen toward black or white, in 256ths.
            def emit_fade(node)
              return unless tiled? || painted?

              mode = node.toward == :white ? Runtime::Tint::TOWARD_WHITE : Runtime::Tint::TOWARD_BLACK
              runtime_call("rt_tint_to", [Build.int(mode), tint_steps(node), Build.int(0)])
            end

            # Reference#exec_tint: the whole screen toward a colour, in 256ths.
            def emit_tint(node)
              return unless tiled? || painted?

              runtime_call("rt_tint_to", [Build.int(Runtime::Tint::TOWARD_COLOR), tint_steps(node),
                                          Build.int(Graphics::Color.resolve(node.color))])
            end

            # How far the fade or tint has gone, in the walk's 256ths, held between none and all
            # (FadeSteps.steps, worked out as the game runs).
            def tint_steps(node)
              steps = FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: true)
              Build.clamped(steps, Build.int(0), Build.int(256))
            end

            def refuse_unmade_backgrounds!
              @backgrounds.each do |bg|
                refuse_unmade!("a status bar") if bg.bar?
                unless bg.tile_w == 8 && bg.tile_h == 8
                  refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}")
                end
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
              end
              sizes = @backgrounds.map { |bg| TileMap.grid(bg.every_map.first) }.uniq
              refuse_unmade!("backgrounds of different sizes on one screen") if sizes.length > 1
              @plane_size = sizes.first
            end

            def refuse_unmade_sprites!
              @objects.each_value do |obj|
                refuse_unmade!("a sprite put in another layer") if obj.layers && !obj.layers.empty?
              end
              return if @objects.empty? || @backgrounds.empty?

              IR::Stacking.screenfuls(@program).each do |screenful|
                scenery = screenful.scenery.reject(&:bar?)
                screenful.objects.each do |obj|
                  level = screenful.depths[obj.name]
                  refuse_unmade!("a sprite behind a background") if scenery.any? { |bg| screenful.depths.of_scenery(bg) > level }
                end
              end
            end

            # WHICH OF THE TWO PLANES EACH BACKGROUND IS ON. A scene's own scenery is in front of the scenery every
            # screen shows, as the interpreter paints it over what is up already, and within each the one drawn
            # last is in front (IR::Stacking, which IR::SceneHandover hands the scenery over in the order of): so
            # the scenes' own take the front planes, A first, as many as the scene with the most has, and the
            # scenery every screen shows the planes behind those. So a stack that puts a scene's own background
            # behind one every screen shows is not made yet.
            def assign_background_layers
              always = @handover.always_up.scenery
              own = @scenes.keys.map { |scene| @handover.arrival(scene).scenery }
              @scene_layers = own.map(&:length).max || 0
              refuse_unmade_stacking!(always)
              always.each_with_index { |bg, i| @layers[bg] = @scene_layers + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
            end

            # A stack the planes' order cannot show: a scene's own background behind one every screen shows.
            def refuse_unmade_stacking!(always)
              @scenes.each_key do |scene|
                own = @handover.arrival(scene).scenery
                drawn = @handover.showing(scene).select { |bg| (always + own).any? { |up| up.equal?(bg) } }
                next if drawn.map(&:object_id) == (always + own).map(&:object_id)

                refuse_unmade!("a scene's own background in a layer behind a background every screen shows")
              end
            end

            def layer_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no plane" }

            def refuse_unmade!(what)
              raise NotMadeYet.new("This game has #{what}. The Genesis build does not make that yet. To fix this, " \
                                   "build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "the picture")
            end

            # Every picture a sprite can show, made into sprite pieces in the order SpriteNames numbers
            # them, so the number a picture is made with is the one a reader of the drawn sprites turns
            # back into its name.
            def make_sprite_art
              return unless tiled?

              poses = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              poses.each do |name|
                image = Assets::Image.of(picture_named(name))
                if recolored?(name)
                  @art.sprite_picture(name, image, palette: @art.ordered_palette(own_colors(image)))
                else
                  @art.sprite_picture(name, image)
                end
              end
              @objects.each_value { |obj| recolor_palettes(obj) }
              @backgrounds.each { |bg| bg.every_map.each_index { |which| grid_of(bg, which) } }
            rescue Art::TooManyLists
              raise NotMadeYet.new("The lists of colours this game draws with need more than the four a Genesis holds at " \
                                   "once. The Genesis build keeps each list for the whole game. It does not swap lists " \
                                   "as the game runs yet. To fix this, draw with fewer lists of colours, or build the " \
                                   "game for the Game Boy Advance alone for now (`consoles: %i[gba]`).", part: "the picture")
            end

            # THE COLOURS A SPRITE CAN BE DRAWN WITH (`draw_with`): every list it names, a palette each whose
            # places are the list's (Art#ordered_palette), and the picture cut into places of its own list, so
            # the sprite is drawn in a list by writing that list's palette's number over the palette its pieces
            # name (Runtime::Tiles, rt_sprite_place). A list the game changes as it runs
            # (`recolor`) keeps a palette that is written over, as the colours it holds change; one that is
            # never changed shares a palette with any other list of the same colours.
            def recolored?(name) = @objects.values.any? { |obj| obj.poses.include?(name) && !obj.recolors.empty? }

            # The colours of the picture's own list, see-through left out.
            def own_colors(image) = image.colors.drop(1).map { |color| color & 0x7FFF }

            # The palette of each list +obj+ is drawn with, in the order the sprite is told them (`recolor` counts
            # from 0 through them), kept for the table the runtime reads.
            def recolor_palettes(obj)
              return if obj.recolors.empty?

              @recolor_lines ||= {}
              @recolor_lines[obj] = obj.recolors.map { |entry| palette_of_list(entry) }
              @recolor_tables ||= []
              @recolor_tables << @recolor_lines[obj] unless @recolor_tables.include?(@recolor_lines[obj])
            end

            # The palette of a list a sprite is drawn with: +entry+ is a name, of a list the game may change, or
            # the colours themselves.
            def palette_of_list(entry)
              return @art.ordered_palette(entry.drop(1).map { |color| color & 0x7FFF }) unless entry.is_a?(Symbol)

              list = color_list_named(entry)
              colors = list.colors.drop(1).map { |color| color & 0x7FFF }
              list.recolors.empty? ? @art.ordered_palette(colors) : @art.reserve_held_palette([:sprites, entry], colors)
            end

            def color_list_named(name)
              @color_lists ||= by_kind(:color_list)
              @color_lists.fetch(name) { raise LoweringError, "the list of colours #{name.inspect} is drawn with and never declared" }
            end

            # Reference#exec_color_list_holds: the list holds the set the game says, written over its palette in
            # the blank. A list nothing is drawn with has no palette, and nothing to show.
            def emit_color_list_holds(node)
              palette = @art.held_palette_of([:sprites, node.name]) or return

              list = color_list_named(node.name)
              label = held_colors_label([:list, node.name], list.colors, list.recolors)
              runtime_call("rt_colors_hold", [LabelAddress.new(label), node.which, Build.int(palette)])
            end

            # Reference#exec_background_colors: each list the background's tiles are drawn from holds the list the
            # game's number names for it, the same list for each and the same step through them all. A list no tile
            # is drawn from has no palette, and nothing to show.
            def emit_background_colors(node) = for_background(node) { |bg| emit_background_colors_of(bg, node) }

            def emit_background_colors_of(bg, node)
              bg.drawn_lists.each_index do |index|
                palette = @art.held_palette_of([:background, bg.object_id, index]) or next

                steps = bg.recolors.map { |step| step.fetch(index) }
                label = held_colors_label([:background, bg.object_id, index], bg.palettes.fetch(index), steps)
                runtime_call("rt_colors_hold", [LabelAddress.new(label), node.which, Build.int(palette)])
              end
            end

            # The table of the colours a palette can be told to hold, which rt_colors_hold reads: +declared+ is the
            # colours it starts with and +steps+ each other set, every one a list with see-through first.
            def held_colors_label(key, declared, steps)
              @held_tables ||= {}
              @held_tables[key] ||= ["art held colors #{@held_tables.length}", declared, steps]
              @held_tables[key].first
            end

            # Each table of sets as data for the Linker: how many sets besides the declared colours, then those and
            # each other set, a palette's places (Art#palette_colors, the game's 15-bit colours) each.
            def write_held_colors(data)
              (@held_tables || {}).each_value do |label, declared, steps|
                data.label(label)
                data.data_words(steps.length)
                [declared, *steps].each { |colors| data.data_words(@art.palette_colors(colors.drop(1))) }
              end
            end

            # The picture each picture of the art is, by number, as SpriteNames numbers it.
            def sprite_picture_names = @art.sprite_pictures.map { |name, _| @sprite_names.picture_number(name) }

            # The art, and each sprite's table of pictures, as sections for the Linker.
            def art_sections
              return [] unless tiled?

              data = M68000.new("art", holds: ART)
              data.label("art colors")
              data.data_words(@art.color_memory)
              data.label("art tile bytes")
              data.data_longs(@art.tile_data.bytesize)
              data.label("art sprite pictures")
              data.data_longs(@art.sprite_pictures.each_value.map { |picture| pieces_label(picture.number) })
              @art.sprite_pictures.each_value do |picture|
                data.label(pieces_label(picture.number))
                data.data_words(picture.pieces.length)
                picture.pieces.each do |piece|
                  data.data_words(piece.dx, piece.dy, piece.tile | (piece.palette << Art::PALETTE_SHIFT))
                end
              end
              write_held_colors(data)
              write_colors15(data) if self.class.changing_colors?(@program)
              data.label("art grids")
              @art.grids.each do |grid|
                data.data_longs(grid_label(grid.number))
                data.data_words(grid.columns, grid.rows)
              end
              @art.grids.each do |grid|
                data.label(grid_label(grid.number))
                data.data_words(grid.words)
              end
              @pose_tables.each do |obj, label|
                data.label(label)
                data.data_words(obj.poses.length, *obj.poses.map { |pose| @art.sprite_pictures.fetch(pose).number })
              end
              (@recolor_tables || []).each do |lines|
                data.label(recolor_table_label(lines))
                data.data_words(lines.length, *lines.map { |line| line << Art::PALETTE_SHIFT })
              end
              [data.section, *tile_section]
            end

            # The game's own colours for the runtime to move (Runtime::Tint): the 64 places of the colour memory
            # and how many of each palette are used.
            def write_colors15(data)
              data.label("colors15")
              data.data_words(@art.colors15)
              data.data_words(@art.colors_used)
            end

            ART = M68000::Holding.new(what: "the game's pictures", fix: "use fewer different pictures and maps")

            def pieces_label(number) = "art pieces #{number}"
            def grid_label(number) = "art grid #{number}"

            private

            # The tiles' pixels, a section of their own.
            def tile_section
              asm = M68000.new("art tiles", holds: ART)
              asm.label("art tiles")
              asm.data_bytes(@art.tile_data.bytes)
              [asm.section]
            end

            # The background's map number +which+ as a grid of cells (Genesis::Art#grid).
            def grid_of(bg, which)
              @grids[[bg.object_id, which]] ||= begin
                map = bg.every_map.fetch(which)
                columns, rows = TileMap.size_of(map)
                cells = map.map { |row| Array(row).map { |tile| cell_of(bg, tile) } }
                @art.grid(cells, columns, rows)
              end
            end

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              image = Assets::Image.of(picture_named(bg.tiles.fetch(tile)))
              bg.recolors.empty? ? @art.background_cell(image) : @art.background_cell(image, palette: recolored_palette(bg, image))
            end

            # THE PALETTE A TILE OF A BACKGROUND THE GAME DRAWS WITH OTHER COLOURS IS DRAWN FROM: one for each list
            # its tiles were drawn from, written over with the colours of the list the game's number names for it
            # (Reference#background_swap). The tile is made of the places of its own list.
            def recolored_palette(bg, image)
              list = bg.recolored_list_of(image.list_drawn_from) or
                raise LoweringError, "a tile of the background #{bg.name.inspect} is drawn from a list of colours it was not given"
              index = bg.drawn_lists.index(list)
              @art.reserve_held_palette([:background, bg.object_id, index], bg.palettes.fetch(index).drop(1).map { |color| color & 0x7FFF })
            end

            # --- the screen and the backgrounds ---

            # Reference#exec_background: put up, showing from its corner (Reference#put_up_background). A scene's
            # own goes up as the scene takes over instead (#emit_scene_arrival).
            def emit_background(node)
              return if @handover.on_arrival?(node)

              emit_put_up(node, 0, reset_view: 1)
            end

            def emit_put_up(bg, which, reset_view:)
              runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, which).number), Build.int(reset_view)])
              note = @put_up_this_pass&.fetch(layer_of(bg)) if reset_view.nonzero?
              statement(Build.set(note, 1)) if note
            end

            # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME
            # (Reference#put_up_background), and the place the game keeps for its view is written at the
            # end of the pass (IR::Frames.loop_in_console_order), after the put-up. So a put-up notes
            # itself for the rest of its pass, a note for each plane, and the write at the end of it leaves
            # the background where it was put up. The wait forgets the notes (#emit_corners_forgotten),
            # and the next pass's write moves it.
            def keep_corner_notes
              return unless @program.walk.any? { |node| node.kind == :scroll_background && placed_at_pass_end?(node) }

              @put_up_this_pass = (0...PLANES).to_h { |plane| [plane, keep_local(:"put_up_this_pass_#{plane}")] }
            end

            # The notes forgotten at a wait: the pass that put a background up has ended.
            def emit_corners_forgotten
              @put_up_this_pass&.each_value { |note| statement(Build.set(note, 0)) }
            end

            # +node+'s write, unless it is written at the end of a pass that put its background up (+note+,
            # #keep_corner_notes).
            def emit_unless_put_up(node, note)
              return yield unless note && placed_at_pass_end?(node)

              held = fresh("held_at_corner")
              jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
              yield
              @asm.label(held)
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names: the one by that name,
            # or — where several scenes each declare their own by one name — the one of the scene whose routine
            # is being lowered, or the one every screen shows. Nil where which it is cannot be told while the
            # game is built (#for_background).
            def background_declared_for(node)
              declared = @backgrounds.select { |bg| bg.name == node.name }
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" if declared.empty?
              return declared.first if declared.length == 1

              own = @lowering_scene && @handover.arrival(@lowering_scene).scenery.find { |bg| bg.name == node.name }
              own || @handover.always_up.scenery.find { |bg| bg.name == node.name }
            end

            # +node+'s change made to the background it names (#background_declared_for), yielded to the block.
            # Where that is not known while the game is built — a change outside every scene's routine, to a
            # name several scenes declare — the change is made to the one of the scene up when it runs, each
            # scene's its own branch.
            def for_background(node)
              bg = background_declared_for(node)
              return yield(bg) if bg

              @scenes.each do |scene, number|
                own = @handover.arrival(scene).scenery.find { |declared| declared.name == node.name }
                next unless own

                other = fresh("not_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
                yield own
                @asm.label(other)
              end
            end

            # Reference#exec_scroll_background.
            def emit_scroll_background(node)
              for_background(node) do |bg|
                emit_unless_put_up(node, @put_up_this_pass&.fetch(layer_of(bg))) do
                  runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
                end
              end
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map.
            def emit_set_tile(node) = for_background(node) { |bg| emit_set_tile_of(bg, node) }

            def emit_set_tile_of(bg, node)
              return if node.tile && node.tile >= bg.tiles.length

              columns, rows = TileMap.size_of(bg.every_map.first)
              cell = cell_of(bg, node.tile)
              word = cell ? cell[0] | (cell[1] << Art::PALETTE_SHIFT) : 0
              column = keep_local(:column)
              row = keep_local(:row)
              value(node.col)
              store(column)
              value(node.row)
              store(row)
              outside = fresh("cell_outside")
              inside = Build.binop(:and, Build.binop(:and, Build.binop(:>=, Build.var_ref(column), Build.int(0)),
                                                         Build.binop(:<, Build.var_ref(column), Build.int(columns))),
                                   Build.binop(:and, Build.binop(:>=, Build.var_ref(row), Build.int(0)),
                                               Build.binop(:<, Build.var_ref(row), Build.int(rows))))
              jump_unless(inside, outside)
              runtime_call("rt_set_cell", [Build.int(layer_of(bg)), Build.var_ref(column), Build.var_ref(row), Build.int(word)])
              @asm.label(outside)
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays
            # where it was.
            def emit_show_map(node) = for_background(node) { |bg| emit_show_map_of(bg, node) }

            def emit_show_map_of(bg, node)
              which = keep_local(:map)
              value(node.which)
              store(which)
              done = fresh("map_shown")
              bg.every_map.each_index do |number|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(number)), other)
                emit_put_up(bg, number, reset_view: 0)
                @asm.bra(done)
                @asm.label(other)
              end
              @asm.label(done)
            end

            # A scene taking over (Lowering#emit_scene): what it shows of its own goes up from its corner, as
            # declared, with every map it chooses back at the first; and the planes its own scenery does not
            # use, which the scene before may have used, come down (IR::SceneHandover). The scenery every
            # screen shows stays as it is.
            # +before+ is the number of the scene up until now, -1 at power-on, when the planes are empty already and
            # an empty map's copy would only run the blank out for the sprites.
            def emit_scene_arrival(scene, before)
              return if painted? || @scene_layers.zero?

              arrival = @handover.arrival(scene)
              arrival.map_choices.each { |var| store_number(var, 0) }
              arrival.scenery.each { |bg| emit_put_up(bg, 0, reset_view: 1) }
              unused = (0...@scene_layers).to_a - arrival.scenery.map { |bg| layer_of(bg) }
              return if unused.empty?

              first = fresh("scene_first")
              jump_unless(Build.binop(:!=, Build.var_ref(before), Build.int(-1)), first)
              unused.each do |plane|
                runtime_call("rt_background_put_up", [Build.int(plane), Build.int(empty_grid.number), Build.int(1)])
              end
              @asm.label(first)
            end

            # A grid of nothing, put up on a plane to take down what was there.
            def empty_grid
              @empty_grid ||= begin
                columns, rows = plane_size
                @art.grid(Array.new(rows) { Array.new(columns) }, columns, rows)
              end
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, the back-most first, each
            # placed by the runtime from its table of pictures — or none at all on the pass after
            # `hide_sprites`. A game with no tiled screen has none to place, and the runtime that
            # places them is not in its cartridge.
            def emit_present_objects(node)
              return unless tiled?

              hidden = sprites_hidden_flag
              placing = fresh("sprites_placed")
              done = fresh("sprites_done")
              call_routine("rt_sprites_begin")
              jump_unless(Build.var_ref(hidden), placing)
              store_number(hidden, 0)
              @asm.bra(done)
              @asm.label(placing)
              present_items(node).each do |item|
                next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                emit_sprite_placing(object_named(item))
              end
              @asm.label(done)
            end

            def object_named(name) = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }

            # One sprite placed, if it is showing.
            def emit_sprite_placing(obj)
              skip = fresh("sprite_off")
              jump_unless(Build.binop(:==, obj.active, Build.int(1)), skip)
              runtime_call("rt_sprite_place", [LabelAddress.new(pose_table(obj)), obj.pose, obj.x, obj.y,
                                               Build.int(@sprite_names.name_number(obj.declared)), *recolor_operands(obj)])
              @asm.label(skip)
            end

            # Which list the sprite is drawn with, as the game says it now, and the table of the palettes the
            # lists have; or two noughts for a sprite drawn in no list but its own.
            def recolor_operands(obj)
              return [Build.int(0), Build.int(0)] if obj.recolors.empty?

              [obj.recolor, LabelAddress.new(recolor_table_label(@recolor_lines.fetch(obj)))]
            end

            def recolor_table_label(lines) = "art recolors #{@recolor_tables.index(lines)}"

            # The frame's sprites back to front, each a name — or, for a run the game orders
            # (`draw_in_order`), the run, at the place of its first sprite.
            def present_items(node)
              Array(node.orders).reduce(node.names.dup) do |names, run|
                first = names.index(run.objects.first)
                names[0...first] + [run] + names[(first + run.objects.length)..]
              end
            end

            # A RUN THE GAME PUTS IN ORDER AS IT RUNS (Reference#names_in_draw_order): its list holds the
            # run's sprites back to front, each by its place in the run, so each entry in turn places
            # the sprite it names. A sprite's placing is a routine of its own (#sprite_placing_sections),
            # so the entries share it.
            def emit_ordered_run(run)
              entry = keep_local(:ordered_entry)
              run.objects.each_index do |k|
                statement(Build.set(entry, Build.list_get(run.order, Build.int(k))))
                past = fresh("past_the_ordered")
                run.objects.each_with_index do |name, at|
                  other = fresh("not_sprite")
                  jump_unless(Build.binop(:==, Build.var_ref(entry), Build.int(at)), other)
                  call_routine(sprite_placing_label(name))
                  @asm.bra(past)
                  @asm.label(other)
                end
                @asm.label(past)
              end
            end

            def sprite_placing_label(name) = (@sprite_placings ||= {})[name] ||= "sprite placing #{@sprite_placings.length}"

            # The routine each sprite of an ordered run is placed by (#emit_ordered_run), made once the
            # game's routines are.
            def sprite_placing_sections
              (@sprite_placings || {}).map do |name, label|
                routine_section(label, [], routine: "placing the sprite #{name.inspect}") { emit_sprite_placing(object_named(name)) }
              end
            end

            # The table of a sprite's pictures: how many, then each one's number.
            def pose_table(obj) = @pose_tables[obj] ||= "poses #{@pose_tables.length}"

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = store_number(sprites_hidden_flag, 1)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
