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
                                                 hide_sprites: :emit_hide_sprites
                                               })

            # The Genesis::Art the game's pictures were made into.
            attr_reader :art

            # The sprite table has this many rows (Console::Description#sprites).
            MOST_SPRITES = Console::GENESIS.sprites

            # The two planes a background can be on: plane A is in front.
            PLANES = 2

            def prepare_picture
              @art = Art.new(backdrop: IR::SceneHandover.of(@program).game_backdrop)
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
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            def refuse_unmade_backgrounds!
              @backgrounds.each do |bg|
                refuse_unmade!("a status bar") if bg.bar?
                unless bg.tile_w == 8 && bg.tile_h == 8
                  refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}")
                end
                refuse_unmade!("a background drawn from several sets of tiles") if bg.several_sets?
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
                unless Array(bg.recolors).empty? && Array(bg.palettes).length <= 1
                  refuse_unmade!("a background drawn with other colours")
                end
              end
              refuse_unmade!("a scene's own background") if @scenes.keys.any? { |scene| !@handover.arrival(scene).scenery.empty? }
              refuse_unmade!("more than two backgrounds on the screen at once") if @backgrounds.length > PLANES
              sizes = @backgrounds.map { |bg| TileMap.grid(bg.every_map.first) }.uniq
              refuse_unmade!("backgrounds of different sizes on one screen") if sizes.length > 1
              @plane_size = sizes.first
            end

            def refuse_unmade_sprites!
              @objects.each_value do |obj|
                refuse_unmade!("a sprite drawn in other colours") unless obj.recolors.empty?
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

            # The layers the backgrounds are on: plane A for the one painted last, B for the one before.
            def assign_background_layers
              @backgrounds.each_with_index { |bg, i| @layers[bg] = @backgrounds.length - 1 - i }
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
                refuse_unmade!("a picture made of pieces") if image.pieces
                @art.sprite_picture(name, image)
              end
              @backgrounds.each { |bg| bg.every_map.each_index { |which| grid_of(bg, which) } }
            end

            # The picture each picture of the art is, by number, as SpriteNames numbers it.
            def sprite_picture_names = @art.sprite_pictures.map { |name, _| @sprite_names.picture_number(name) }

            # The art, and each sprite's table of pictures, as sections for the Linker.
            def art_sections
              return [] unless tiled?

              data = M68000.new("art", holds: ART)
              data.label("art colors")
              data.data_words(@art.cgram)
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
              [data.section, *tile_section]
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

              @art.background_cell(Assets::Image.of(picture_named(bg.tiles.fetch(tile))))
            end

            # --- the screen and the backgrounds ---

            # Reference#exec_background: put up, showing from its corner (Reference#put_up_background).
            def emit_background(node) = emit_put_up(node, 0, reset_view: 1)

            def emit_put_up(bg, which, reset_view:)
              runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, which).number), Build.int(reset_view)])
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names.
            def background_declared_for(node)
              @backgrounds.find { |bg| bg.name == node.name } ||
                raise(LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}")
            end

            # Reference#exec_scroll_background.
            def emit_scroll_background(node)
              bg = background_declared_for(node)
              runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map.
            def emit_set_tile(node)
              bg = background_declared_for(node)
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
            def emit_show_map(node)
              bg = background_declared_for(node)
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

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, the back-most first, each
            # placed by the runtime from its table of pictures — or none at all on the pass after
            # `hide_sprites`.
            def emit_present_objects(node)
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
                                               Build.int(@sprite_names.name_number(obj.declared))])
              @asm.label(skip)
            end

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
