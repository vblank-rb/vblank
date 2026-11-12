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
          # a picture of the painted art (PS1::PaintedArt), drawn in front of every plane, or, where the stack
          # puts a background in front of a sprite, at its level of the stack (#picture_levels). A status bar is
          # a plane too, drawn from its top row down, in front of every other plane and behind every sprite.
          #
          # Everything such a screen shows is read through a colour table, so its colours changing as the game
          # runs (a list told to hold another set, a background drawn with other lists, a fade, a tint) are
          # tables written again by Runtime::Colors, from the sources and tables made here (#color_sections).
          module Picture
            # The steps that change colours as the game runs (Runtime::Colors).
            COLOR_CHANGES = %i[color_list_holds background_colors fade tint].freeze
            STATEMENT_KINDS = (%i[background scroll_background place_bar set_tile show_map present_objects hide_sprites] +
                               COLOR_CHANGES).freeze

            def emit_picture_statement(node)
              case node.kind
              when :background then emit_background(node)
              when :scroll_background then emit_scroll_background(node)
              when :place_bar then emit_place_bar(node)
              when :set_tile then emit_set_tile(node)
              when :show_map then emit_show_map(node)
              when :present_objects then emit_present_objects(node)
              when :hide_sprites then emit_hide_sprites(node)
              when :color_list_holds then emit_color_list_holds(node)
              when :background_colors then emit_background_colors(node)
              when :fade then emit_palette_walk(node)
              when :tint then emit_palette_walk(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether +program+'s screen is drawn from tiles and changes its colours as it runs.
            def self.changes_colors?(program) = tiled?(program) && program.walk.any? { |node| COLOR_CHANGES.include?(node.kind) }

            # Whether +program+'s screen is drawn from tiles: it says `screen :tiled`, or it has a background
            # or a sprite and paints nothing. A game that paints (Paint) keeps its painted screen, unless it shows a
            # screen drawn from tiles too (#crosses?), which then has everything a screen drawn from tiles has.
            def self.tiled?(program)
              return true if crosses?(program)

              modes = program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              return false if modes.include?(:bitmap)
              return false if modes.empty? && program.walk.any? { |node| node.kind != :screen && Paint::STATEMENT_KINDS.include?(node.kind) }

              program.walk.any? { |node| %i[background object].include?(node.kind) || (node.kind == :screen && node.mode == :tiled) }
            end

            # WHETHER +program+ SHOWS A PAINTED SCREEN AND ONE DRAWN FROM TILES, at different times: it says `screen
            # :tiled`, and `screen :bitmap` or paints. Handing over from one kind to the other replaces the whole
            # picture (IR::SceneHandover.crossing?), which the runtime keeps by whether tiles are up
            # (Runtime::Tiles::TILES_UP): only while they are is the picture drawn from tiles as each pass ends.
            def self.crosses?(program)
              screens = program.walk.select { |node| node.kind == :screen }.map(&:mode)
              return false unless screens.include?(:tiled)

              screens.include?(:bitmap) || program.walk.any? { |node| node.kind != :screen && Paint::STATEMENT_KINDS.include?(node.kind) }
            end

            # Whether +program+'s screen is painted and shows sprites over what it paints (`sprite ..., over_picture:
            # true`, IR::SpritesOverPicture), which Runtime::Paint draws over the page as it is shown.
            def self.over_picture?(program) = !tiled?(program) && IR::SpritesOverPicture.any?(program)

            # How big a tile is, and a plane's cells each way where nothing goes up on it.
            TILE_SIDE = 8
            PLANE_CELLS = Runtime::Tiles::PAGE_SIDE / TILE_SIDE
            # Tiles kept one above another in a column of the sheet: video RAM's whole height of them.
            TILES_PER_COLUMN = Console::PS1Hardware::VRAM_HEIGHT / TILE_SIDE

            # What a cell of a map's table holds for no tile, and what a table of tiles a number picks from
            # holds for a number that stands for none.
            NO_TILE = 0
            NO_PICK = 0xFFFF_FFFF

            # What the runtime draws the game's screen drawn from tiles with (Runtime::Tiles::Screen), and nil for a
            # game whose screen is painted (Runtime.sections's +tiled+).
            def tiled_screen
              return nil unless @tiled

              bars = @layers.select { |bg, _| bg.bar? }.values.uniq.sort
              Runtime::Tiles::Screen.new(places: @plane_places, depths: @plane_depths, opaque: @opaque_planes, bar_planes: bars,
                                         levels: @levels, crosses: @crosses)
            end

            def prepare_picture
              @tiled = Picture.tiled?(@program)
              @crosses = Picture.crosses?(@program)
              @over_picture = Picture.over_picture?(@program)
              @objects = @program.walk.select { |node| node.kind == :object }.to_h { |node| [node.name, node] }
              @backgrounds = @program.walk.select { |node| node.kind == :background }
              @sprite_names = SpriteNames.new(@program)
              @layers = {}.compare_by_identity
              @grids = {}
              @tile_slots = {}
              @pose_tables = {}
              @pose_set_tables = {}
              @pick_tables = {}
              @changes_colors = Picture.changes_colors?(@program) || Paint.by_number?(@program)
              @color_sources = {}
              @sprite_list_tables = {}
              @sprite_list_places = {}
              @level_tables = {}
            end

            def tiled? = @tiled

            # Each piece of a picture this lowering does not make yet, refused by name: it makes a tiled
            # screen of 8×8 tiles, backgrounds whose maps fit one plane, and plain sprites in front of them; and on
            # a painted screen, backgrounds stamped where they are put up and sprites over the picture.
            def refuse_unmade_picture!
              refuse_fades_of_part!
              return refuse_unmade_painted! unless @tiled

              others = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq - %i[tiled bitmap]
              refuse_unmade!(TILED_SCREEN, "shows a `screen :#{others.first}`") unless others.empty?
              refuse_unmade_crossing! if @crosses
              if @program.walk.any? { |node| node.kind == :tile_pose }
                refuse_unmade!(TILED_SCREEN, "draws a sprite's pose from sprite tiles it loads (`sprite_tiles`)")
              end
              refuse_backdrops_of_its_own!
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            # The steps that make the interpreter paint a painted screen's backgrounds again as it runs
            # (Reference#collect_definitions' @repaints): one moved, changed or put in a stack, which this build
            # does not make on a painted screen.
            REPAINTING_KINDS = %i[scroll_background place_bar box_background scroll_rows affine_background set_tile show_map
                                  background_colors tile_run layers].freeze

            # WHAT A PAINTED SCREEN SHOWS BESIDE WHAT IT PAINTS, as this build makes it: backgrounds stamped onto the
            # picture as they are put up and never moved or changed after (#emit_stamp_background), and sprites
            # over the picture (`over_picture: true`) that neither turn nor resize, nor follow a list the game
            # changes. A sprite painted into the picture, which puts the scenery back under it as it moves
            # (Reference#restore_scene_rect), is not made yet.
            def refuse_unmade_painted!
              unless @backgrounds.empty?
                kinds = @program.walk.map(&:kind).uniq & REPAINTING_KINDS
                unless kinds.empty?
                  refuse_unmade!(TILED_SCREEN, "moves, changes or stacks a background on a painted (bitmap) screen " \
                                               "(`#{kinds.first}`)")
                end
                @backgrounds.each { |bg| refuse_unmade_stamp!(bg) }
              end
              return if @objects.empty?

              unless @objects.each_value.all?(&:over_picture)
                refuse_unmade!(TILED_SCREEN, "draws sprites into a painted (bitmap) screen (without `over_picture: true`)")
              end
              if @program.walk.any? { |node| node.kind == :color_list_holds }
                refuse_unmade!(TILED_SCREEN, "changes a list of colours on a painted (bitmap) screen with sprites over it")
              end
              refuse_unmade_sprites!
            end

            # A GAME THAT SHOWS A PAINTED SCREEN AND ONE DRAWN FROM TILES, as this build makes it: its backgrounds are
            # each a scene's own, on a scene drawn from tiles, and go up as the scene takes over; and nothing changes
            # its colours as it runs. A background every screen shows, which goes up again each time tiles come
            # back (IR::SceneHandover#always_up), one stamped onto a painted scene, and a fade, a tint or a list of
            # colours that changes, read through tables on one screen and baked into the picture on the other, are
            # not made yet.
            def refuse_unmade_crossing!
              if fades? || @program.walk.any? { |node| %i[color_list_holds background_colors].include?(node.kind) }
                refuse_unmade!(FADES, "fades, tints or changes the colours of a game that shows both a painted (bitmap) " \
                                      "screen and one drawn from tiles")
              end
              @backgrounds.each do |bg|
                tiled_scene = bg.scene && @handover.on_arrival?(bg) && SceneHandover.tiles?(scene_screen(bg.scene))
                next if tiled_scene

                refuse_unmade!(TILED_SCREEN, "shows a background outside a scene drawn from tiles, in a game that also " \
                                             "shows a painted (bitmap) screen")
              end
            end

            # The kind of screen +scene+ draws on (SceneHandover::Arrival#mode), as a `screen` names it.
            def scene_screen(scene) = IR::Modes::SCREEN_OF_MODE.fetch(@handover.arrival(scene).mode)

            # A background stamped onto a painted screen: one of a scene's own, a status bar, one held above a row
            # and one drawn with other colours are not made yet.
            def refuse_unmade_stamp!(bg)
              refuse_unmade!(TILED_SCREEN, "shows a scene's own background on a painted (bitmap) screen") if bg.scene
              refuse_unmade!(TILED_SCREEN, "shows a status bar on a painted (bitmap) screen") if bg.bar?
              refuse_unmade!(TILED_SCREEN, "holds a background above a row on a painted (bitmap) screen") if bg.above_row
              return if bg.recolors.empty? && !bg.follows_several?

              refuse_unmade!(TILED_SCREEN, "draws a background with other lists of colours on a painted (bitmap) screen")
            end

            # A FADE OF PART OF THE SCREEN, placed under a layer or held to a rectangle, is a blend, which the
            # colour tables cannot give: every picture drawn through a table changes with it, wherever it is, a
            # painted screen drawn by number (PS1::PaintedNumbers) as much as one drawn from tiles.
            # How the graphics chip's own mixing does it is decided when it is made (Console::PS1Answers::UNMADE_VERBS).
            def refuse_fades_of_part!
              return unless @program.walk.any? { |node| node.kind == :fade && (node.under || node.reaches) }

              refuse_unmade!(FADES, "fades part of the screen (`fade ..., under:` or `inside:`)")
            end

            # A `screen` that sets a backdrop of its own beside the game's: a scene's own.
            def refuse_backdrops_of_its_own!
              game_backdrop = @handover.game_backdrop
              return unless @program.walk.any? { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }

              refuse_unmade!(TILED_SCREEN, "has a scene that shows a backdrop of its own (`screen ... backdrop:`)")
            end

            def refuse_unmade_backgrounds!
              @backgrounds.each do |bg|
                refuse_unmade!(TILED_SCREEN, "has background tiles of #{bg.tile_w}×#{bg.tile_h}") unless bg.tile_w == 8 && bg.tile_h == 8
                refuse_unmade!(TILED_SCREEN, "has a background held above a row (`above_row:`)") if bg.above_row
                if bg.streams?
                  refuse_unmade!(TILED_SCREEN, "has a background whose map is more than #{TileMap.max_grid_size} cells across " \
                                               "or down, or whose maps are of different sizes")
                end
              end
            end

            def refuse_unmade_sprites!
              @objects.each_value do |obj|
                if obj.follows_each&.any? && !obj.recolors.empty?
                  refuse_unmade!(TILED_SCREEN, "has a sprite that follows the lists its poses are drawn from and is also drawn " \
                                               "with other lists (`draw_with`)")
                end
                unless constant_number?(obj.angle, 0) && constant_number?(obj.scale, Build::SCALE_ONE)
                  refuse_unmade!(TILED_SCREEN, "turns or resizes a sprite")
                end
              end
            end

            def constant_number?(node, number) = node.is_a?(Node) && node.kind == :int && node.value == number

            # HOW MANY LEVELS THE PICTURE IS DRAWN IN, a level at a time (Runtime::Tiles::Screen#levels), or nil where
            # it is drawn as every background and then every sprite in the order the pass placed them. That is the
            # same picture unless a sprite can sit at a level behind a background, or the sprites' levels are not
            # in the order the frame places them, so they are drawn level by level only then
            # (Reference#repaint_view; IR::Stacking#depths). A sprite that changes layer can do both.
            def picture_levels
              return nil if @objects.empty?

              stacking = @cache.stacking
              depths = stacking.depths
              return depths.count if @objects.each_value.any? { |obj| obj.layers && !obj.layers.empty? }
              return depths.count if IR::Stacking.scenery_over_objects?(depths, scenery: stacking.scenery, objects: stacking.objects)

              levels = stacking.objects.map { |obj| depths[obj.name] }
              levels.each_cons(2).all? { |back, front| back <= front } ? nil : depths.count
            end

            # How deep +bg+ sits (IR::Stacking#depths), or Runtime::Tiles::BAR_LEVEL for a status bar, which sits at no
            # level.
            def background_level(bg) = bg.bar? ? Runtime::Tiles::BAR_LEVEL : @cache.stacking.depths.of_scenery(bg)

            # How deep +obj+ sits as the frame places it (Reference#object_level): the level of the layer its number
            # picks (Nodes::Object#layer_pick), or of the one it was declared in for a number naming none of them.
            def sprite_level(obj)
              depths = @cache.stacking.depths
              declared = depths[obj.name]
              return Build.int(declared) if obj.layers.nil? || obj.layers.empty?

              levels = obj.layers.map { |layer| depths[IR::Stacking.choice_name(obj, layer)] }
              table = @level_tables[[declared, *levels]] ||= "tiles sprite levels #{@level_tables.length}"
              level = @sprite_level ||= keep_local(:sprite_level)
              picked = fresh_label("level_picked")
              # The number one more, so the table's first entry, the declared layer's level, is for a number naming
              # none: -1 is 0, and past the layers is out of the table.
              emit_value(Build.var_ref(obj.layer_pick))
              @asm.addiu(:v0, :v0, 1)
              @asm.sltiu(:t0, :v0, levels.length + 1)
              @asm.bne(:t0, :zero, picked) { @asm.sll(:v0, :v0, 2) }
              @asm.move(:v0, :zero)
              @asm.label(picked)
              @asm.la(:t1, table)
              @asm.addu(:t1, :t1, :v0)
              @asm.lw(:v0, 0, :t1)
              emit_store(level)
              Build.var_ref(level)
            end

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
              refuse_unmade_stacking!
              always.each_with_index { |bg, i| @layers[bg] = @scene_planes + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
              count = @scene_planes + always.length
              if count > Runtime::Tiles::MOST_PLANES
                refuse_unmade!(TILED_SCREEN, "shows more than #{Runtime::Tiles::MOST_PLANES} backgrounds on its screens together")
              end
              @plane_places = texture_memory.reserve_planes(Array.new(count) { |plane| plane_size(plane) }) or
                refuse_unmade!(TILED_SCREEN, "has backgrounds whose maps together are bigger than the video memory kept for them")
              make_plane_tables(count)
              # The planes every background that goes up on draws every pixel of (Runtime::Tiles::Screen#opaque): one
              # of those up hides the backdrop and every plane behind it. A status bar is drawn below the rows the
              # other planes are, so it hides nothing behind it.
              @opaque_planes =(0...count).select do |plane|
                showing = backgrounds_on(plane)
                !showing.empty? && showing.all? { |bg| !bg.bar? && opaque_background?(bg) }
              end
              @levels = picture_levels
              follow_backdrop_list
              make_tile_sheet
            end

            # The backgrounds that go up on plane +plane+.
            def backgrounds_on(plane) = @layers.select { |_, number| number == plane }.keys

            # HOW DEEP EACH PLANE IS, and each background's colour table (PS1::PlaneColors). A plane is kept at
            # 4 bits a texel where every background that goes up on it has 15 entries or fewer besides the
            # see-through one, at 8 where each has 255 or fewer, and at 15, the colours themselves, past that:
            # the fewer bits, the less the chip reads drawing it. Each background has a table of its own, kept
            # (TextureMemory#reserve_table) since it may be written as the game runs, and placed now, since the
            # code that puts the background up names it.
            def make_plane_tables(count)
              @plane_colors = {}.compare_by_identity
              @layers.each_key do |bg|
                @plane_colors[bg] = PlaneColors.new(bg, image_of: ->(key) { @cache.image(picture_named(key)) },
                                                        list_named: ->(name) { color_list_named(name) })
              end
              @plane_depths = Array.new(count) do |plane|
                most = backgrounds_on(plane).map { |bg| @plane_colors[bg].entries.length }.max.to_i
                TextureMemory::TABLE_COLORS.find { |depth, capacity| most < capacity }&.first || 15
              end
              @plane_tables = {}.compare_by_identity
              unchanging = {}
              @layers.each do |bg, plane|
                depth = @plane_depths.fetch(plane)
                colors = @plane_colors[bg]
                if depth == 15
                  refuse_unmade!(TILED_SCREEN, "draws a background of more than 255 colours with other colours") if colors.changes?
                  refuse_unmade!(FADES, "fades or tints a background of more than 255 colours") if fades?
                  next
                end
                entries = [0, *colors.entries.map { |entry| TextureMemory.texel_for_color(entry.colors.first) }]
                capacity = TextureMemory::TABLE_COLORS.fetch(depth)
                @plane_tables[bg] = if colors.changes?
                                      table = texture_memory.reserve_table(capacity: capacity, entries: entries)
                                      colors.entries.each_with_index do |entry, at|
                                        add_color_patch(entry.source, [table, at + 1], entry.colors) if entry.source
                                      end
                                      table
                                    else
                                      # Backgrounds whose colours never change and are the same read one table.
                                      unchanging[[capacity, entries]] ||= texture_memory.reserve_table(capacity: capacity, entries: entries)
                                    end
              end
            end

            # Whether the game fades or tints its screen.
            def fades? = @program.walk.any? { |node| %i[fade tint].include?(node.kind) }

            # WHETHER +bg+ DRAWS EVERY PIXEL wherever it is scrolled: every one of its tiles draws all of its pixels,
            # every cell of each map's grid (TileMap.grid, which comes round) names a tile, and nothing the game
            # does empties a cell (`set_tile` of no tile). A background whose tiles are read from the player's copy
            # (+from_file+) is not known to.
            def opaque_background?(bg)
              return false if bg.from_file
              return false unless bg.tiles.each_index.all? { |tile| @plane_colors[bg].tile_entries(tile).none?(&:nil?) }
              return false if @program.walk.any? { |node| node.kind == :set_tile && node.name == bg.name && !node.picked? && node.tile.nil? }

              bg.every_map.all? do |map|
                columns, rows = TileMap.grid(map)
                (0...rows).all? do |row|
                  cells = Array(map[row])
                  (0...columns).all? { |column| (tile = cells[column]) && tile >= 0 && tile < bg.tiles.length }
                end
              end
            end

            # The word a plane's textured rectangle names +bg+'s colour table by, in its top half; nought for a
            # plane of colours.
            def plane_table_word(bg) = (table = @plane_tables[bg]) ? table.field << 16 : 0

            # The list of colours declared by +name+.
            def color_list_named(name)
              @color_lists_declared ||= @program.walk.select { |node| node.kind == :color_list }.to_h { |node| [node.name, node] }
              @color_lists_declared.fetch(name) { raise LoweringError, "the list of colours #{name.inspect} is drawn with and never declared" }
            end

            # How big plane +plane+ is, [width, height] in pixels: the biggest grid of the maps that go up on it.
            def plane_size(plane)
              grids = backgrounds_on(plane).flat_map { |bg| bg.every_map.map { |map| TileMap.grid(map) } }
              [grids.map(&:first).max || PLANE_CELLS, grids.map(&:last).max || PLANE_CELLS].map { |cells| cells * TILE_SIDE }
            end

            # A stack the planes' order cannot show: a scene's own background behind one every screen shows.
            def refuse_unmade_stacking!
              return unless @scenes.each_key.any? { |scene| @handover.own_scenery_behind_shared?(scene) }

              refuse_unmade!(TILED_SCREEN, "puts a scene's own background in a layer behind a background every screen shows")
            end

            def plane_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no plane" }

            # THE SHEET OF TILES: every tile any background can show, as its plane holds it (#tile_halfwords),
            # kept once however many backgrounds and cells show it the same, in columns of TILES_PER_COLUMN
            # tiles from the first column past the planes. A tile is only ever copied, so where it sits needs
            # no texture page. Each slot is TILE_SIDE halfwords across whatever the plane's depth, a tile of
            # places at its left.
            def make_tile_sheet
              @layers.each_key do |bg|
                bg.tiles.each_index { |tile| tile_slot(bg, tile) }
              end
              slots = @tile_slots.values.uniq.length
              @blank_slot = slot_for_halfwords(Array.new(TILE_SIDE * TILE_SIDE, 0))
              columns = ((slots + 1 + TILES_PER_COLUMN - 1) / TILES_PER_COLUMN) * TILE_SIDE
              @sheet_column = texture_memory.reserve_columns(columns)
            end

            # The slot in the sheet of +bg+'s tile number +tile+.
            def tile_slot(bg, tile) = (@tile_slots[[bg.object_id, tile]] ||= slot_for_halfwords(tile_halfwords(bg, tile)))

            # +bg+'s tile number +tile+ as the plane it goes up on holds it, TILE_SIDE halfwords a row: its colours
            # at 15 bits (0000h see-through), or its places in the background's table, packed, each row filled
            # out with nought.
            def tile_halfwords(bg, tile)
              entries = @plane_colors[bg].tile_entries(tile)
              depth = @plane_depths.fetch(plane_of(bg))
              return entries.map { |entry| TextureMemory.texel_for_color(entry&.colors&.first) } if depth == 15

              place_of = @plane_colors[bg].entries.each_with_index.to_h { |entry, at| [entry, at + 1] }
              packed = TextureMemory.pack_places(entries.map { |entry| entry ? place_of.fetch(entry) : 0 }, TILE_SIDE, depth)
              packed.each_slice(packed.length / TILE_SIDE).flat_map { |row| row + Array.new(TILE_SIDE - row.length, 0) }
            end

            def slot_for_halfwords(halfwords)
              @sheet_halfwords ||= {}
              @sheet_halfwords[halfwords] ||= @sheet_halfwords.length
            end

            # Where the tile in sheet slot +slot+ is in video RAM, y << 16 | x.
            def tile_place(slot)
              x = @sheet_column + ((slot / TILES_PER_COLUMN) * TILE_SIDE)
              y = (slot % TILES_PER_COLUMN) * TILE_SIDE
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
              return emit_stamp_background(node) unless @tiled

              emit_put_up(node, 0, reset_view: 1)
            end

            # A BACKGROUND PUT UP ON A PAINTED SCREEN is painted into the picture, as the interpreter stamps it
            # (Reference#stamp_background): its map from the screen's corner, each cell's tile, the pixels its tiles
            # leave see-through not drawn. Nothing moves or changes it after (#refuse_unmade_painted!), so the part
            # of it the screen shows is one picture of the painted art, made while the game is built, and putting
            # it up is one blit of that picture.
            def emit_stamp_background(bg)
              runtime_call("rt_paint_blit", [stamp_picture(bg), Build.int(0), Build.int(0)])
            end

            # The part of +bg+'s map on the screen as a picture (Reference#stamp_background): on a screen wider or
            # taller than the map's grid, the grid comes round and is seen again (#stamp_repeats).
            def stamp_picture(bg)
              LabelAddress.new(painted_art.register_picture([:stamp, bg.object_id]) do
                colors = PlaneColors.new(bg, image_of: ->(key) { @cache.image(picture_named(key)) },
                                             list_named: ->(name) { color_list_named(name) })
                width = Console::PS1Hardware::SCREEN_WIDTH
                height = Console::PS1Hardware::SCREEN_HEIGHT
                columns, rows = TileMap.grid(bg.map)
                across, down = stamp_repeats(bg, columns, rows)
                drawn = {}
                down.times do |round_down|
                  across.times do |round_across|
                    bg.map.each_with_index do |row, r|
                      Array(row).each_with_index do |tile, c|
                        next if tile.nil? || tile.negative? || tile >= bg.tiles.length

                        left = (round_across * columns * TILE_SIDE) + (c * bg.tile_w)
                        top = (round_down * rows * TILE_SIDE) + (r * bg.tile_h)
                        colors.tile_entries(tile).each_with_index do |entry, at|
                          x = left + (at % bg.tile_w)
                          y = top + (at / bg.tile_w)
                          drawn[[x, y]] = painted_color(entry.colors.first) if entry && x < width && y < height
                        end
                      end
                    end
                  end
                end
                drawn
              end)
            end

            # How many times +bg+'s grid of +columns+ by +rows+ cells is seen across the screen and down it
            # (Reference#grid_repeats): once for a map shown a strip at a time, too big for a grid, or of tiles that
            # are not 8 × 8.
            def stamp_repeats(bg, columns, rows)
              return [1, 1] if bg.streams? || !TileMap.fits?(bg.map) || bg.tile_w != TILE_SIDE || bg.tile_h != TILE_SIDE

              [Console::PS1Hardware::SCREEN_WIDTH.fdiv(columns * TILE_SIDE).ceil,
               Console::PS1Hardware::SCREEN_HEIGHT.fdiv(rows * TILE_SIDE).ceil]
            end

            # A status bar put up from its corner shows from the top it was declared with (Reference#bar_top_shown).
            def emit_put_up(bg, which, reset_view:)
              columns, rows = TileMap.grid(bg.every_map.fetch(which))
              runtime_call("rt_plane_put_up", [Build.int(plane_of(bg)), LabelAddress.new(grid_label(bg, which)), Build.int(reset_view),
                                               Build.int(columns.bit_length - 1), Build.int(rows), Build.int(plane_table_word(bg)),
                                               Build.int(background_level(bg))])
              return if reset_view.zero?

              emit_bar_put_up(bg) if bg.bar?
              note = @put_up_this_pass&.fetch(plane_of(bg))
              statement(Build.set(note, 1)) if note
            end

            # A STATUS BAR PUT UP shows from the top it was declared with, and the runtime's one top and one setting
            # for covering sprites become this bar's (IR::SceneHandover#bar_covers_on_put_up). The top the game
            # keeps is placed at the end of every pass the bar is up (Builder#finalize_status_bars).
            def emit_bar_put_up(bg)
              runtime_call("rt_bar_place", [Build.int(bg.bar_top)])
              covers = @handover.bar_covers_on_put_up(bg)
              runtime_call("rt_bar_covers", [covers]) if covers
            end

            # The label of the table of +bg+'s map number +which+, made with the art (#picture_sections).
            def grid_label(bg, which) = (@grids[[bg.object_id, which]] ||= ["tiles grid #{@grids.length}", bg, which]).first

            # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME
            # (Reference#put_up_background), as the Genesis's lowering keeps it
            # (Genesis::Lowering::Picture#keep_corner_notes): a put-up notes itself for the rest of its pass,
            # a note for each plane, and the scroll, or a status bar's top, written at the end of the pass leaves
            # it where it was put up. The wait forgets the notes.
            def keep_corner_notes
              return unless @tiled && @plan.places_at_pass_end?(:scroll_background, :place_bar)

              @put_up_this_pass = (0...@plane_places.length).to_h { |plane| [plane, keep_local(:"put_up_this_pass_#{plane}")] }
            end

            def emit_clear_corner_notes
              @put_up_this_pass&.each_value { |note| emit_store_number(note, 0) }
            end

            def emit_unless_put_up(node, note)
              return yield unless note && @plan.placed_at_pass_end?(node)

              held = fresh_label("held_at_corner")
              jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
              yield
              @asm.label(held)
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names: the one by that name,
            # or, where several scenes each declare one by that name, the one of the scene whose routine is being
            # lowered, or the one every screen shows; nil where that cannot be told while the game is built.
            def background_declared_for(node) = @handover.background_named(node, scene: @lowering_scene, error: LoweringError)

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

            # Reference#exec_place_bar: a background that is not a status bar has no top to place. Whether it covers
            # sprites is set wherever it is written; its top not at the end of a pass that put it up.
            def emit_place_bar(node)
              for_background(node) do |bg|
                next unless bg.bar?

                runtime_call("rt_bar_covers", [node.covers]) if node.covers
                emit_unless_put_up(node, @put_up_this_pass&.fetch(plane_of(bg))) { runtime_call("rt_bar_place", [node.top]) }
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
            # at, is a place in a table of where each picked tile is in video RAM; one past either end, one whose
            # entry is nil, or one standing for no tile the background has (NO_PICK), changes nothing
            # (Reference#tile_picked, Nodes::SetTile).
            def emit_set_picked_tile_of(bg, node, columns, rows)
              places = node.picks.map { |tile| tile && tile < bg.tiles.length ? cell_place(bg, tile) : NO_PICK }
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
              emit_arrival_screen(@handover.arrival(scene)) if @crosses
              return unless @tiled && @scene_planes.positive?

              arrival = @handover.arrival(scene)
              arrival.map_choices.each { |var| emit_store_number(var, 0) }
              arrival.scenery.each { |bg| emit_put_up(bg, 0, reset_view: 1) }
              ((0...@scene_planes).to_a - arrival.scenery.map { |bg| plane_of(bg) }).each do |plane|
                runtime_call("rt_plane_take_down", [Build.int(plane)])
              end
            end

            # A SCENE TAKING OVER IN A GAME THAT SHOWS BOTH KINDS OF SCREEN puts its own screen up first, since changing
            # the kind wipes what went up before it (Reference#take_over): the `screen` it writes, or, for one that
            # writes none, the kind it draws on, which changes the screen only where the kind differs
            # (Reference#cross_to_scene_screen).
            def emit_arrival_screen(arrival)
              return emit_screen(arrival.screen) if arrival.screen

              screen = IR::Modes::SCREEN_OF_MODE.fetch(arrival.mode)
              emit_screen_kind(SceneHandover.tiles?(screen), pages: arrival.mode == IR::Modes::BUFFERED ? 2 : 1, implied: true)
            end

            # A `screen` in a game that shows both kinds (#crosses?): +tiles+ for one drawn from tiles. Where the kind
            # up is the other, the picture is wiped and every plane taken down (Runtime::Tiles' rt_screen_cross,
            # Reference#exec_screen); then the screen is one page or two, +pages+ (a screen drawn from tiles is always
            # two, since its whole picture is drawn again each pass). An +implied+ screen, a scene's that writes
            # none, changes nothing where the kind up is the same.
            def emit_screen_kind(tiles, pages:, implied: false)
              same = fresh_label("same_kind_of_screen")
              paged = [Build.int(tiles || pages == 2 ? 1 : 0)]
              emit_load_word(:t0, runtime_place(Runtime::Tiles::TILES_UP))
              tiles ? @asm.bne(:t0, :zero, same) : @asm.beq(:t0, :zero, same)
              runtime_call("rt_screen_cross", [Build.int(tiles ? 1 : 0)])
              runtime_call("rt_paint_screen", paged) if implied
              @asm.label(same)
              runtime_call("rt_paint_screen", paged) unless implied
            end

            # --- colours that change as the game runs (Runtime::Colors) ---

            # A SOURCE OF COLOURS: its table's label, how many sets it can name (the declared colours first), and
            # each entry it changes, [where, its colour in each set]: where is [a colour table, a place in it], or
            # :backdrop.
            ColorSource = Data.define(:label, :sets, :entries)

            # The source PlaneColors::Source +source+ names, made the first time it is asked for.
            def color_source(source)
              @color_sources[source.key] ||= ColorSource.new(label: "colors source #{@color_sources.length}", sets: source.sets, entries: [])
            end

            # +where+ changes with +source+, showing +colors+, one for each of its sets.
            def add_color_patch(source, where, colors) = color_source(source).entries << [where, colors]

            # The source a list of colours the game changes is, by the list's name.
            def list_source(name) = PlaneColors::Source.of_list(color_list_named(name))

            # A BACKDROP THAT FOLLOWS A LIST (Nodes::ColorList#backdrop_place) is the colour at its place in the set
            # the list holds now (Reference#exec_color_list_holds), so it is one more entry the list changes.
            def follow_backdrop_list
              list = @program.walk.find { |node| node.kind == :color_list && node.backdrop_place } or return

              sets = [list.colors, *list.recolors].map { |set| set.fetch(list.backdrop_place) & 0x7FFF }
              add_color_patch(list_source(list.name), :backdrop, sets)
            end

            # Reference#exec_color_list_holds: everything drawn with the list shows the set the game names, from
            # the picture this pass draws. A painted screen draws nothing with a list (Reference#exec_blit draws
            # a picture's own colours) but a sprite, a background and a backdrop, which this build refuses there
            # (#refuse_unmade_picture!, Lowering#refuse_unmade_parts!), so on one it changes nothing.
            def emit_color_list_holds(node)
              return unless @tiled

              runtime_call("rt_colors_hold", [LabelAddress.new(color_source(list_source(node.name)).label), node.which])
            end

            # Reference#exec_background_colors: the background's tiles show the colours of the step the game
            # names, by the background's own source (PlaneColors). One that is drawn with no other lists has none.
            #
            # The interpreter keeps the number by the background's NAME (Reference#exec_background_colors), so a
            # scene's background of that name that goes up later shows it too: every declaration of the name is
            # told, each through its own source.
            def emit_background_colors(node)
              @layers.each_key do |bg|
                next if bg.name != node.name || bg.recolors.empty? || bg.follows_several?

                runtime_call("rt_colors_hold", [LabelAddress.new(color_source(PlaneColors::Source.of_background(bg)).label), node.which])
              end
            end

            # Reference#exec_fade and #exec_tint, which on a console that cannot blend walk every colour shown
            # (IR::Fading; PaletteWalk says what the walk is and when it is done, Runtime::Colors does it here).
            def emit_palette_walk(node)
              walk = PaletteWalk.walk_for(node)
              runtime_call("rt_tint_to", [Build.int(walk.toward), walk.steps, Build.int(walk.color)])
            end

            # Whether the list of colours +name+ is told to hold other sets as the game runs.
            def changing_list?(name)
              @changing_lists ||= @program.walk.filter_map { |node| node.name if node.kind == :color_list_holds }.to_set
              @changing_lists.include?(name) && !color_list_named(name).recolors.empty?
            end

            # THE TABLES OF COLOURS AND THEIR SOURCES, for Runtime::Colors: the game's colours (the backdrop's, then
            # every colour table's entries, as each starts), room for the colours shown, how many halfwords those
            # are, each table's place and size, and each source's sets. Made once every texture has its table and
            # place (Paint#paint_sections).
            def color_sections
              return [] unless @changes_colors

              # A picture kept at 15 bits, past what the lists of colours hold, has no list for a fade to walk. On a
              # painted screen drawn by number, its texels are numbers too, and walked as the page is copied.
              if @tiled && fades? && texture_memory.textures.any? { |texture| texture.depth == 15 }
                refuse_unmade!(FADES, "fades or tints pictures whose colours do not fit the lists of colours the PlayStation keeps")
              end
              # A painted screen drawn by number walks only the table it is shown through: its pictures' tables
              # hold numbers, which must stay as they are.
              tables = @tiled ? texture_memory.tables : [@numbers_table]
              starts = {}.compare_by_identity
              at = 4 # past the backdrop's word
              tables.each do |table|
                starts[table] = at
                at += table.capacity * 2
              end
              halfwords = 2 + tables.sum(&:capacity)
              asm = R3000.new("colors", holds: TABLES_HOLDING)
              asm.label(Runtime::Colors::BASE)
              asm.data_halves(TextureMemory.texel_for_color(@handover.game_backdrop.to_i & 0x7FFF), 0)
              tables.each { |table| asm.data_halves(Array.new(table.capacity) { |at| table.entries[at] || 0 }) }
              asm.label(Runtime::Colors::SHOWN)
              asm.data_halves(Array.new(halfwords, 0))
              asm.label(Runtime::Colors::HALFWORDS)
              asm.data_words(halfwords)
              asm.label(Runtime::Colors::TABLES)
              asm.data_words(tables.length)
              tables.each { |table| asm.data_words((table.y << 16) | table.x, (1 << 16) | table.capacity, starts[table], table.capacity / 2) }
              @color_sources.each_value { |source| write_color_source(asm, source, starts) }
              [asm.section]
            end

            # A source's table (Runtime::Colors): the set it holds, how many besides the declared colours, how many
            # entries, where each is in "colors base", then each set's colours.
            def write_color_source(asm, source, starts)
              asm.align
              asm.label(source.label)
              asm.data_words(0, source.sets - 1, source.entries.length)
              asm.data_words(source.entries.map { |where, _| where == :backdrop ? 0 : starts[where.first] + (where.last * 2) })
              source.sets.times do |set|
                asm.data_halves(source.entries.map { |_, colors| TextureMemory.texel_for_color(colors.fetch(set)) })
              end
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, the back-most first, each placed by
            # the runtime from its table of pictures; or none at all on the pass after `hide_sprites`.
            def emit_present_objects(node)
              return unless @tiled || @over_picture

              hidden = sprites_hidden_flag
              placing = fresh_label("sprites_placed")
              done = fresh_label("sprites_done")
              call_routine("rt_sprites_begin")
              jump_unless(Build.var_ref(hidden), placing)
              emit_store_number(hidden, 0)
              @asm.b(done)
              @asm.label(placing)
              IR::Stacking.items_in_draw_order(node).each do |item|
                next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                emit_sprite_placing(object_named(item))
              end
              @asm.label(done)
            end

            # The routine Runtime::Paint's rt_paint_sprites_shown calls on a tear-free screen.
            SPRITES_OVER_PICTURE = "game sprites over picture"

            # SPRITES OVER A TEAR-FREE PAINTED SCREEN are placed again in the gap where a pass's page is published,
            # from the numbers the pass just finished (Reference#advance_frame), and the page goes to the screen with
            # them; the game's own step places them after the wait from the same numbers. So the frame's sprite
            # step is a routine of its own too, which the runtime calls as it copies the page (rt_paint_sprites_shown),
            # on a tear-free screen alone. A section for a game with sprites over its painted screen; none for any
            # other.
            def sprites_over_picture_section
              return [] unless @over_picture

              step = IR::SpritesOverPicture.frame_sprite_step(@program)
              [routine_section(SPRITES_OVER_PICTURE, [], routine: "the sprites over the picture") { emit_present_objects(step) if step }]
            end

            # A RUN THE GAME PUTS IN ORDER AS IT RUNS: its list holds the run's sprites back to front, each by its
            # place in the run, so each entry in turn places the sprite it names. Each sprite's placing is written
            # once, as a routine of its own ending in a return, and an entry picks it from a table of their
            # addresses kept beside the code: a few instructions an entry, whatever the run's length. As many
            # entries are read as the run has sprites, which is the length the builder keeps the list at, and an
            # entry read past the list's end stops the game, as the interpreter's read does. An entry naming no
            # sprite of the run, which the builder never writes and the interpreter stops on, places none here.
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
              table = obj.recolors.empty? ? LabelAddress.new(pose_table(obj.poses, followed_lists(obj))) : emit_recolored_pose_table(obj)
              level = [sprite_level(obj)] if @levels
              runtime_call("rt_sprite_place", [table, obj.pose, obj.x, obj.y, Build.int(@sprite_names.name_number(obj.declared)), *level])
              @asm.label(skip)
            end

            # A SPRITE WHOSE POSES FOLLOW THE LISTS THEY ARE DRAWN FROM (Object#follows_each, Reference#object_color_list):
            # each pose drawn from a list the game changes shows what the list holds now, so its picture is read
            # through the list's colour table (#sprite_picture_following), and every other pose as it is drawn.
            # For each pose, the list it follows, or nil.
            def followed_lists(obj)
              obj.poses.map do |pose|
                list = obj.follows_each && obj.list_followed_by_pose(@cache.image(picture_named(pose)).colors_name)
                list if list && changing_list?(list)
              end
            end

            # A SPRITE DRAWN WITH ANOTHER LIST OF COLOURS (`draw_with`, Reference#object_color_list): its pictures
            # are made again in each list it can be drawn with, a table of them each, and the number the game
            # keeps picks the table: a number naming none of the lists draws its own colours. Kept in a number of
            # the lowering's own, which the placing reads.
            def emit_recolored_pose_table(obj)
              tables = [nil, *obj.recolors].map { |colors| pose_table(obj.poses, Array.new(obj.poses.length, colors_of_list(colors))) }
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

            # The colours +entry+ of a sprite's lists stands for: the colours themselves, those a declared list
            # holds, or, for a list the game changes, its name, whose colours its table holds now
            # (Reference#colors_held_by).
            def colors_of_list(entry)
              return entry unless entry.is_a?(Symbol)
              return entry if changing_list?(entry)

              color_list_named(entry).colors
            end

            # The table of a sprite's pictures, each pose in its colours in +colors+ (#sprite_picture's: nil for its
            # own): how many, then each one's number (SpriteNames#picture_number) and its picture in the painted
            # art. Sprites that face the same poses in the same colours read one table.
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
              return [] unless @tiled || @over_picture

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
                poses.zip(colors) { |pose, color| asm.data_words(@sprite_names.picture_number(pose), sprite_picture(pose, color).label) }
              end
              @pose_set_tables.each do |tables, label|
                asm.label(label)
                asm.data_words(tables)
              end
              @level_tables.each do |levels, label|
                asm.label(label)
                asm.data_words(levels)
              end
              upload_tile_sheet if @tiled
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
              return sprite_picture_following(name, colors) if colors.is_a?(Symbol)

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

            # THE PICTURE +name+ DRAWN WITH THE LIST +list+ THE GAME CHANGES: read through the list's own colour table
            # for sprites, 256 entries, which the list's source writes as it changes (Runtime::Colors). Each pixel is
            # an entry of it, by the colours it shows in each of the list's sets (Reference#recolor_of_picture).
            def sprite_picture_following(name, list)
              table = @sprite_list_tables[list] ||= texture_memory.reserve_table(capacity: TextureMemory::TABLE_COLORS.fetch(8), entries: [0])
              LabelAddress.new(painted_art.register_picture([:image, name, :following, list], table: table) do
                image = @cache.image(picture_named(name))
                declared = color_list_named(list)
                sets = [declared.colors, *declared.recolors].map { |set| Assets::Recolor.of(image, set) }
                drawn = {}
                (image.width * image.height).times do |at|
                  next unless image.drawn_at?(at)

                  colors = sets.map { |recolor| recolor.color_for(at, image.raw_at(at)) & 0x7FFF }
                  drawn[[at % image.width, at / image.width]] = sprite_list_place(list, table, colors)
                end
                drawn
              end)
            end

            # The place in +list+'s table for sprites of the entry showing +colors+, one for each set, added the first
            # time it is asked for.
            def sprite_list_place(list, table, colors)
              (@sprite_list_places[list] ||= {})[colors] ||= begin
                if table.entries.length >= table.capacity
                  refuse_unmade!(TILED_SCREEN, "draws its sprites in more than #{table.capacity - 1} colours of the list " \
                                               ":#{list}, which it changes as it runs")
                end
                table.entries << TextureMemory.texel_for_color(colors.first)
                add_color_patch(list_source(list), [table, table.entries.length - 1], colors)
                table.entries.length - 1
              end
            end

            # The sheet's tiles copied into video RAM at power-on, a column of tiles a copy.
            def upload_tile_sheet
              @sheet_halfwords.keys.each_slice(TILES_PER_COLUMN).with_index do |column, number|
                texture_memory.add_upload(x: @sheet_column + (number * TILE_SIDE), y: 0, width: TILE_SIDE,
                                          height: column.length * TILE_SIDE, halfwords: column.flatten)
              end
            end
          end
        end
      end
    end
  end
end
