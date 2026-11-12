# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # A SCREEN DRAWN FROM TILES, lowered for a PlayStation: its backgrounds and sprites as calls into
          # Runtime::Tiles, and what they draw with made while the program is built. Mixed into Lowering.
          #
          # Each background the game declares is given one of the runtime's planes (a picture of its map in
          # video RAM), the one declared last in front, as the interpreter paints the one declared last
          # over the rest. Each map it can show is made into a table of cells, each the place in video RAM
          # of the tile it shows, which the runtime copies onto the plane as the map goes up. Every tile a
          # background can show is kept once in a sheet of tiles in video RAM, beside the planes. A sprite is
          # a picture of the painted art (PS1::PaintedArt), drawn in front of every plane.
          module Picture
            STATEMENT_KINDS = %i[background scroll_background set_tile show_map present_objects hide_sprites].freeze

            def emit_picture_statement(node)
              case node.kind
              when :background then emit_background(node)
              when :scroll_background then emit_scroll_background(node)
              when :set_tile then emit_set_tile(node)
              when :show_map then emit_show_map(node)
              when :present_objects then emit_present_objects(node)
              when :hide_sprites then emit_hide_sprites(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether +program+'s screen is drawn from tiles: it says `screen :tiled`, or it has a background
            # or a sprite and paints nothing. A game that paints (Paint) keeps its painted screen.
            def self.tiled?(program)
              modes = program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              return false if modes.include?(:bitmap)
              return false if modes.empty? && program.walk.any? { |node| node.kind != :screen && Paint::STATEMENT_KINDS.include?(node.kind) }

              program.walk.any? { |node| %i[background object].include?(node.kind) || (node.kind == :screen && node.mode == :tiled) }
            end

            # How big a tile is, and a plane's cells each way where nothing goes up on it.
            TILE_SIDE = 8
            PLANE_CELLS = Runtime::Tiles::PAGE_SIDE / TILE_SIDE
            # Tiles kept one above another in a column of the sheet: video RAM's whole height of them.
            TILES_A_COLUMN = Console::PS1Hardware::VRAM_HEIGHT / TILE_SIDE

            # What a cell of a map's table holds for no tile, and what a table of tiles a number picks from
            # holds for a number that stands for none.
            NO_TILE = 0
            NO_PICK = 0xFFFF_FFFF

            # Where each plane is in video RAM, [x, y] by its number, for a game whose screen is drawn from
            # tiles, and nil for any other (Runtime.sections's +planes+).
            def plane_places = @plane_places

            def prepare_picture
              @tiled = Picture.tiled?(@program)
              @objects = @program.walk.select { |node| node.kind == :object }.to_h { |node| [node.name, node] }
              @backgrounds = @program.walk.select { |node| node.kind == :background }
              @sprite_names = SpriteNames.new(@program)
              @layers = {}.compare_by_identity
              @grids = {}
              @tile_slots = {}
              @pose_tables = {}
              @pose_set_tables = {}
              @pick_tables = {}
            end

            def tiled? = @tiled

            # Each piece of a picture this lowering does not make yet, refused by name: it makes a tiled
            # screen of 8×8 tiles, backgrounds whose maps fit one plane, and plain sprites in front of them.
            def refuse_unmade_picture!
              painted = !@tiled && (@backgrounds.any? || @objects.any?)
              refuse_unmade!(TILED_SCREEN, "draws sprites or backgrounds on a painted (bitmap) screen") if painted
              return unless @tiled

              others = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq - %i[tiled]
              refuse_unmade!(TILED_SCREEN, "shows a `screen :#{others.first}`") unless others.empty?
              if @program.walk.any? { |node| node.kind == :tile_pose }
                refuse_unmade!(TILED_SCREEN, "draws a sprite's pose from sprite tiles it loads (`sprite_tiles`)")
              end
              refuse_backdrops_of_its_own!
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            # A `screen` that sets a backdrop of its own beside the game's: a scene's own.
            def refuse_backdrops_of_its_own!
              game_backdrop = @handover.game_backdrop
              return unless @program.walk.any? { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }

              refuse_unmade!(TILED_SCREEN, "has a scene that shows a backdrop of its own (`screen ... backdrop:`)")
            end

            def refuse_unmade_backgrounds!
              @backgrounds.each do |bg|
                refuse_unmade!(TILED_SCREEN, "shows a status bar") if bg.bar?
                refuse_unmade!(TILED_SCREEN, "has background tiles of #{bg.tile_w}×#{bg.tile_h}") unless bg.tile_w == 8 && bg.tile_h == 8
                refuse_unmade!(TILED_SCREEN, "has a background held above a row (`above_row:`)") if bg.above_row
                if bg.streams?
                  refuse_unmade!(TILED_SCREEN, "has a background whose map is more than #{TileMap.max_grid_size} cells across " \
                                               "or down, or whose maps are of different sizes")
                end
                refuse_unmade!(TILED_SCREEN, "draws a background with other colors (`draw_with`)") unless bg.recolors.empty?
              end
            end

            def refuse_unmade_sprites!
              @objects.each_value do |obj|
                refuse_unmade!(TILED_SCREEN, "puts a sprite in another layer") if obj.layers && !obj.layers.empty?
                unless constant_number?(obj.angle, 0) && constant_number?(obj.scale, Build::SCALE_ONE)
                  refuse_unmade!(TILED_SCREEN, "turns or resizes a sprite")
                end
              end
              return if @objects.empty? || @backgrounds.empty?

              IR::Stacking.screenfuls(@program).each do |screenful|
                scenery = screenful.scenery.reject(&:bar?)
                screenful.objects.each do |obj|
                  level = screenful.depths[obj.name]
                  refuse_unmade!(TILED_SCREEN, "puts a sprite behind a background") if scenery.any? { |bg| screenful.depths.of_scenery(bg) > level }
                end
              end
            end

            def constant_number?(node, number) = node.is_a?(Node) && node.kind == :int && node.value == number

            # WHICH PLANE EACH BACKGROUND IS ON, as the Genesis's lowering gives its planes
            # (Genesis::Lowering::Picture#assign_background_layers): a scene's own scenery in the front
            # planes, 0 first, as many as the scene with the most has, and the scenery every screen shows
            # behind those; within each, the one drawn last in front. The planes are then given their
            # places in video RAM.
            def assign_planes
              return unless @tiled

              always = @handover.always_up.scenery
              own = @scenes.keys.map { |scene| @handover.arrival(scene).scenery }
              @scene_planes = own.map(&:length).max || 0
              refuse_unmade_stacking!(always)
              always.each_with_index { |bg, i| @layers[bg] = @scene_planes + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
              count = @scene_planes + always.length
              if count > Runtime::Tiles::MOST_PLANES
                refuse_unmade!(TILED_SCREEN, "shows more than #{Runtime::Tiles::MOST_PLANES} backgrounds on its screens together")
              end
              @plane_places = texture_memory.reserve_planes(Array.new(count) { |plane| plane_size(plane) }) or
                refuse_unmade!(TILED_SCREEN, "has backgrounds whose maps together are bigger than the video memory kept for them")
              make_tile_sheet
            end

            # How big plane +plane+ is, [width, height] in pixels: the biggest grid of the maps that go up on it.
            def plane_size(plane)
              grids = @layers.select { |_, number| number == plane }.keys.flat_map { |bg| bg.every_map.map { |map| TileMap.grid(map) } }
              [grids.map(&:first).max || PLANE_CELLS, grids.map(&:last).max || PLANE_CELLS].map { |cells| cells * TILE_SIDE }
            end

            # A stack the planes' order cannot show: a scene's own background behind one every screen shows.
            def refuse_unmade_stacking!(always)
              @scenes.each_key do |scene|
                own = @handover.arrival(scene).scenery
                drawn = @handover.showing(scene).select { |bg| (always + own).any? { |up| up.equal?(bg) } }
                next if drawn.map(&:object_id) == (always + own).map(&:object_id)

                refuse_unmade!(TILED_SCREEN, "puts a scene's own background in a layer behind a background every screen shows")
              end
            end

            def plane_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no plane" }

            # THE SHEET OF TILES: every tile any background can show, as its pixels are drawn (a see-through
            # one nil, Reference#tile_colors), kept once however many backgrounds and cells show it, in
            # columns of TILES_A_COLUMN tiles from the first column past the planes. A tile is only ever
            # copied, so where it sits needs no texture page; it is held at 15 bits, as a plane is.
            def make_tile_sheet
              @backgrounds.each do |bg|
                bg.tiles.each_index { |tile| tile_slot(bg, tile) }
              end
              slots = @tile_slots.values.uniq.length
              blank = Array.new(TILE_SIDE * TILE_SIDE)
              @blank_slot = slot_for_colors(blank)
              columns = ((slots + 1 + TILES_A_COLUMN - 1) / TILES_A_COLUMN) * TILE_SIDE
              @sheet_column = texture_memory.reserve_columns(columns)
            end

            # The slot in the sheet of +bg+'s tile number +tile+.
            def tile_slot(bg, tile)
              key = bg.tiles.fetch(tile)
              @tile_slots[key] ||= begin
                image = @cache.image(picture_named(key))
                slot_for_colors(Array.new(image.width * image.height) { |at| image.tile_see_through_at?(at) ? nil : image.color_at(at) })
              end
            end

            def slot_for_colors(colors)
              @sheet_colors ||= {}
              @sheet_colors[colors] ||= @sheet_colors.length
            end

            # Where the tile in sheet slot +slot+ is in video RAM, y << 16 | x.
            def tile_place(slot)
              x = @sheet_column + ((slot / TILES_A_COLUMN) * TILE_SIDE)
              y = (slot % TILES_A_COLUMN) * TILE_SIDE
              (y << 16) | x
            end

            # Where the tile +bg+'s cell showing +tile+ is copied from, or NO_TILE for no tile.
            def cell_place(bg, tile)
              return NO_TILE if tile.nil? || tile.negative?

              tile_place(tile_slot(bg, tile))
            end

            # --- the screen and the backgrounds ---

            # Reference#exec_background: put up, showing from its corner. A scene's own goes up as the scene
            # takes over instead (#emit_scene_arrival).
            def emit_background(node)
              return if @handover.on_arrival?(node)

              emit_put_up(node, 0, reset_view: 1)
            end

            def emit_put_up(bg, which, reset_view:)
              columns, rows = TileMap.grid(bg.every_map.fetch(which))
              runtime_call("rt_plane_put_up", [Build.int(plane_of(bg)), LabelAddress.new(grid_label(bg, which)), Build.int(reset_view),
                                               Build.int(columns.bit_length - 1), Build.int(rows)])
              note = @put_up_this_pass&.fetch(plane_of(bg)) if reset_view.nonzero?
              statement(Build.set(note, 1)) if note
            end

            # The label of the table of +bg+'s map number +which+, made with the art (#picture_sections).
            def grid_label(bg, which) = (@grids[[bg.object_id, which]] ||= ["tiles grid #{@grids.length}", bg, which]).first

            # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME
            # (Reference#put_up_background), as the Genesis's lowering keeps it
            # (Genesis::Lowering::Picture#keep_corner_notes): a put-up notes itself for the rest of its pass,
            # a note for each plane, and the scroll written at the end of the pass leaves it where it was put
            # up. The wait forgets the notes.
            def keep_corner_notes
              return unless @tiled && @program.walk.any? { |node| node.kind == :scroll_background && placed_at_pass_end?(node) }

              @put_up_this_pass = (0...@plane_places.length).to_h { |plane| [plane, keep_local(:"put_up_this_pass_#{plane}")] }
            end

            def emit_corners_forgotten
              @put_up_this_pass&.each_value { |note| emit_store_number(note, 0) }
            end

            def emit_unless_put_up(node, note)
              return yield unless note && placed_at_pass_end?(node)

              held = fresh_label("held_at_corner")
              jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
              yield
              @asm.label(held)
            end

            def placed_at_pass_end?(node)
              @placed_at_pass_end ||= @plan.game_loops.flat_map { |loop_node| console_loop(loop_node).placed.flat_map { |write| write.walk.to_a } }
                                           .to_set(&:object_id)
              @placed_at_pass_end.include?(node.object_id)
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names: the one by that name,
            # or, where several scenes each declare one by that name, the one of the scene whose routine is being
            # lowered, or the one every screen shows; nil where that cannot be told while the game is built.
            def background_declared_for(node)
              declared = @backgrounds.select { |bg| bg.name == node.name }
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" if declared.empty?
              return declared.first if declared.length == 1

              own = @lowering_scene && @handover.arrival(@lowering_scene).scenery.find { |bg| bg.name == node.name }
              own || @handover.always_up.scenery.find { |bg| bg.name == node.name }
            end

            # +node+'s change made to the background it names, yielded to the block; where that is not known
            # while the game is built, to the one of the scene up when it runs, each scene its own branch.
            def for_background(node)
              bg = background_declared_for(node)
              return yield(bg) if bg

              @scenes.each do |scene, number|
                own = @handover.arrival(scene).scenery.find { |declared| declared.name == node.name }
                next unless own

                other = fresh_label("not_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
                yield own
                @asm.label(other)
              end
            end

            # Reference#exec_scroll_background.
            def emit_scroll_background(node)
              for_background(node) do |bg|
                emit_unless_put_up(node, @put_up_this_pass&.fetch(plane_of(bg))) do
                  runtime_call("rt_plane_scroll", [Build.int(plane_of(bg)), node.x, node.y])
                end
              end
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor does a
            # cell outside its map, which the runtime tests against the map's size.
            def emit_set_tile(node) = for_background(node) { |bg| emit_set_tile_of(bg, node) }

            def emit_set_tile_of(bg, node)
              columns, rows = TileMap.size_of(bg.every_map.first)
              return emit_set_picked_tile_of(bg, node, columns, rows) if node.picked?
              return if node.tile && node.tile >= bg.tiles.length

              place = node.tile.nil? ? tile_place(@blank_slot) : cell_place(bg, node.tile)
              runtime_call("rt_plane_cell", [Build.int(plane_of(bg)), node.col, node.row, Build.int(place), Build.int(columns),
                                             Build.int(rows)])
            end

            # A TILE PICKED AS THE GAME RUNS (Nodes::SetTile#picked_by): the number, less the one the picks start
            # at, is a place in a table of where each picked tile is in video RAM; one past either end, or one
            # standing for no tile the background has (NO_PICK), changes nothing (Reference#tile_picked).
            def emit_set_picked_tile_of(bg, node, columns, rows)
              places = node.picks.map do |tile|
                next tile_place(@blank_slot) if tile.nil?

                tile < bg.tiles.length ? cell_place(bg, tile) : NO_PICK
              end
              return if places.all?(NO_PICK)

              table = @pick_tables[places] ||= "tiles picks #{@pick_tables.length}"
              picked = @picked_tile ||= keep_local(:picked_tile)
              none = fresh_label("no_pick")
              emit_value(Build.binop(:-, node.picked_by, Build.int(node.picks_from)))
              @asm.sltiu(:t0, :v0, places.length)
              @asm.beq(:t0, :zero, none)
              @asm.sll(:v0, :v0, 2)
              @asm.la(:t1, table)
              @asm.addu(:t1, :t1, :v0)
              @asm.lw(:v0, 0, :t1)
              @asm.li(:t0, NO_PICK)
              @asm.beq(:v0, :t0, none)
              emit_store(picked)
              runtime_call("rt_plane_cell", [Build.int(plane_of(bg)), node.col, node.row, Build.var_ref(picked), Build.int(columns),
                                             Build.int(rows)])
              @asm.label(none)
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays where it was.
            def emit_show_map(node) = for_background(node) { |bg| emit_show_map_of(bg, node) }

            def emit_show_map_of(bg, node)
              which = keep_local(:map)
              emit_value(node.which)
              emit_store(which)
              done = fresh_label("map_shown")
              bg.every_map.each_index do |number|
                other = fresh_label("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(number)), other)
                emit_put_up(bg, number, reset_view: 0)
                @asm.b(done)
                @asm.label(other)
              end
              @asm.label(done)
            end

            # A scene taking over (Lowering#emit_scene): what it shows of its own goes up from its corner, as
            # declared, with every map it chooses back at the first; and the front planes its own scenery does not
            # use, which the scene before may have used, come down (IR::SceneHandover). The scenery every screen
            # shows stays as it is.
            def emit_scene_arrival(scene)
              return unless @tiled && @scene_planes.positive?

              arrival = @handover.arrival(scene)
              arrival.map_choices.each { |var| emit_store_number(var, 0) }
              arrival.scenery.each { |bg| emit_put_up(bg, 0, reset_view: 1) }
              ((0...@scene_planes).to_a - arrival.scenery.map { |bg| plane_of(bg) }).each do |plane|
                runtime_call("rt_plane_take_down", [Build.int(plane)])
              end
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, the back-most first, each placed by
            # the runtime from its table of pictures; or none at all on the pass after `hide_sprites`.
            def emit_present_objects(node)
              return unless @tiled

              hidden = sprites_hidden_flag
              placing = fresh_label("sprites_placed")
              done = fresh_label("sprites_done")
              call_routine("rt_sprites_begin")
              jump_unless(Build.var_ref(hidden), placing)
              emit_store_number(hidden, 0)
              @asm.b(done)
              @asm.label(placing)
              present_items(node).each do |item|
                next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                emit_sprite_placing(object_named(item))
              end
              @asm.label(done)
            end

            # The frame's sprites back to front, each a name, or, for a run the game orders (`draw_in_order`),
            # the run, at the place of its first sprite (Reference#names_in_draw_order).
            def present_items(node)
              Array(node.orders).reduce(node.names.dup) do |names, run|
                first = names.index(run.objects.first)
                names[0...first] + [run] + names[(first + run.objects.length)..]
              end
            end

            # A RUN THE GAME PUTS IN ORDER AS IT RUNS: its list holds the run's sprites back to front, each by its
            # place in the run, so each entry in turn places the sprite it names. Each sprite's placing is written
            # once, as a routine of its own ending in a return, and an entry picks it from a table of their
            # addresses kept beside the code: a few instructions an entry, whatever the run's length. An entry
            # read past the list's end stops the game, as the interpreter's read does; one naming no sprite of the
            # run places none.
            def emit_ordered_run(run)
              table = fresh_label("ordered_placings")
              past = fresh_label("past_ordered_placings")
              placings = run.objects.map { fresh_label("ordered_placing") }
              @asm.b(past)
              @asm.label(table)
              @asm.data_words(placings)
              run.objects.each_with_index do |name, place|
                @asm.label(placings[place])
                emit_push(:ra)
                emit_sprite_placing(object_named(name))
                emit_pop(:ra)
                @asm.jr(:ra)
              end
              @asm.label(past)
              run.objects.each_index do |k|
                none = fresh_label("order_names_none")
                emit_value(Build.list_get(run.order, Build.int(k)))
                @asm.sltiu(:t0, :v0, run.objects.length)
                @asm.beq(:t0, :zero, none)
                @asm.sll(:v0, :v0, 2)
                @asm.la(:t1, table)
                @asm.addu(:t1, :t1, :v0)
                @asm.lw(:t1, 0, :t1)
                @asm.jalr(:t1)
                @asm.label(none)
              end
            end

            def object_named(name) = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }

            # One sprite placed if it is showing (Reference#objects_on_screen: its `active` is 1), from the table
            # of its pictures in the colours it is drawn with now.
            def emit_sprite_placing(obj)
              skip = fresh_label("sprite_off")
              jump_unless(Build.binop(:==, obj.active, Build.int(1)), skip)
              table = obj.recolors.empty? ? LabelAddress.new(pose_table(obj.poses, nil)) : emit_recolored_pose_table(obj)
              runtime_call("rt_sprite_place", [table, obj.pose, obj.x, obj.y, Build.int(@sprite_names.name_number(obj.declared))])
              @asm.label(skip)
            end

            # A SPRITE DRAWN WITH ANOTHER LIST OF COLOURS (`draw_with`, Reference#object_color_list): its pictures
            # are made again in each list it can be drawn with, a table of them each, and the number the game
            # keeps picks the table: a number naming none of the lists draws its own colours. Kept in a number of
            # the lowering's own, which the placing reads.
            def emit_recolored_pose_table(obj)
              tables = [nil, *obj.recolors].map { |colors| pose_table(obj.poses, colors_of_list(colors)) }
              choice = @pose_set_tables[tables] ||= "tiles pose sets #{@pose_set_tables.length}"
              picked = @picked_poses ||= keep_local(:picked_poses)
              own = fresh_label("own_colors")
              emit_value(obj.recolor)
              @asm.addiu(:v0, :v0, 1)
              @asm.sltiu(:t0, :v0, tables.length)
              @asm.bne(:t0, :zero, own) { @asm.sll(:v0, :v0, 2) }
              @asm.move(:v0, :zero)
              @asm.label(own)
              @asm.la(:t1, choice)
              @asm.addu(:t1, :t1, :v0)
              @asm.lw(:v0, 0, :t1)
              emit_store(picked)
              Build.var_ref(picked)
            end

            # The colours +entry+ of a sprite's lists stands for: the colours themselves, or those a declared list
            # holds (Reference#colors_held_by: the game never changes what one holds in a build that makes this).
            def colors_of_list(entry)
              return entry unless entry.is_a?(Symbol)

              list = @program.walk.find { |node| node.kind == :color_list && node.name == entry } or
                raise LoweringError, "the list of colours #{entry.inspect} is drawn with and never declared"
              list.colors
            end

            # The table of a sprite's pictures, in the colours +colors+ (nil for their own): how many, then each
            # one's number (SpriteNames#picture_number) and its picture in the painted art. Sprites that face the
            # same poses in the same colours read one table.
            def pose_table(poses, colors) = (@pose_tables[[poses, colors]] ||= "tiles poses #{@pose_tables.length}")

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = emit_store_number(sprites_hidden_flag, 1)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)

            # --- the art, as sections for the Linker ---

            # Every map's table of cells, the tables of picked tiles and of each sprite's pictures, where each
            # picture a sprite can show is in the painted art, and the sheet of tiles copied into video RAM at
            # power-on. Made once every routine is, and before the painted art's (Paint#paint_sections), since
            # a sprite's pictures are registered with it here.
            def picture_sections
              return [] unless @tiled

              asm = R3000.new("tiles tables", holds: TABLES_HOLDING)
              @grids.each_value do |label, bg, which|
                asm.label(label)
                asm.data_words(grid_words(bg, bg.every_map.fetch(which)))
              end
              @pick_tables.each do |places, label|
                asm.label(label)
                asm.data_words(places)
              end
              @pose_tables.each do |(poses, colors), label|
                asm.label(label)
                asm.data_words(poses.length)
                poses.each { |pose| asm.data_words(@sprite_names.picture_number(pose), sprite_picture(pose, colors).label) }
              end
              @pose_set_tables.each do |tables, label|
                asm.label(label)
                asm.data_words(tables)
              end
              upload_tile_sheet
              [asm.section]
            end

            # The cells of +map+ as its table: its grid's columns a row, its grid's rows (TileMap.grid), each
            # where its tile is.
            def grid_words(bg, map)
              columns, rows = TileMap.grid(map)
              Array.new(columns * rows) do |at|
                row = map[at / columns]
                cell_place(bg, row && Array(row)[at % columns])
              end
            end

            # The picture +name+ in the painted art, in its own colours (+colors+ nil) or drawn with the list
            # +colors+: each pixel shows the colour at its place in that list (Reference#recolor_of_picture).
            def sprite_picture(name, colors)
              return register_image_picture(name) unless colors

              LabelAddress.new(painted_art.register_picture([:image, name, colors]) do
                image = @cache.image(picture_named(name))
                recolor = Assets::Recolor.of(image, colors)
                drawn = {}
                (image.width * image.height).times do |at|
                  drawn[[at % image.width, at / image.width]] = recolor.color_for(at, image.raw_at(at)) if image.drawn_at?(at)
                end
                drawn
              end)
            end

            # The sheet's tiles copied into video RAM at power-on, a column of tiles a copy.
            def upload_tile_sheet
              @sheet_colors.keys.each_slice(TILES_A_COLUMN).with_index do |column, number|
                halfwords = column.flat_map { |colors| colors.map { |color| TextureMemory.texel_for_color(color) } }
                texture_memory.add_upload(x: @sheet_column + (number * TILE_SIDE), y: 0, width: TILE_SIDE,
                                          height: column.length * TILE_SIDE, halfwords: halfwords)
              end
            end
          end
        end
      end
    end
  end
end
