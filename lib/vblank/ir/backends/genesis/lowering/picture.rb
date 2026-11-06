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
              @art = Art.new(backdrop: @cache.handover.game_backdrop, exact: self.class.fading?(@program),
                             beside_painting: painted?, scene_tiles: @scene_tiles)
              @objects = by_kind(:object)
              @backgrounds = @program.walk.select { |node| node.kind == :background }
              @sprite_names = SpriteNames.new(@program)
              @grids = {}
              @cells_made = {}
              @pose_tables = {}
              @layers = {}.compare_by_identity
            end

            # Whether the game draws from tiles: it has a background or a sprite.
            def tiled? = self.class.picture_of(@program) == :tiled

            # Whether a painted screen shows sprites over its picture (`sprite ..., over_picture: true`):
            # sprites of the tiled screen's kind, placed over the plane the picture is on
            # (Runtime::Paint), from the tiles past the picture's and the three palettes it leaves.
            # A sprite declared on a painted screen is one of these, or none at all.
            public def sprites_over_picture? = painted? && !@objects.empty?

            # Whether the game places sprites in the console's sprite table.
            def places_sprites? = tiled? || sprites_over_picture?

            # The tile in video RAM a sprite's piece names for tile 0 of the art: the first on a tiled
            # screen, and the first past the picture's on a painted one.
            def sprite_tiles_from = painted? ? Runtime::Paint::SPRITE_TILES_FROM : 0

            # How the picture is laid out for the runtime: the plane's columns and rows of cells, which
            # every background of the game shares.
            def plane_size = @plane_size || [32, 32]

            # Each piece of the picture this lowering does not make yet, refused by name: the build
            # makes a tiled screen of 8×8 tiles, at most two backgrounds of one size that every
            # screen shows, and plain sprites in front of them, or a painted screen with no background
            # over it and the sprites it shows over the picture.
            def refuse_unmade_picture!
              refuse_unmade!("a sprite's pose drawn from sprite tiles the game loads (`sprite_tiles`)") if @program.walk.any? { |node| node.kind == :tile_pose }
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              others = screens - %i[tiled bitmap]
              refuse_unmade!("a `screen :#{others.first}`") unless others.empty?
              refuse_unmade!("both a painted (bitmap) screen and a tiled one") if screens.include?(:tiled) && painted?
              refuse_unmade!("a background on a painted (bitmap) screen") if painted? && !@backgrounds.empty?
              refuse_unmade!("a camera on a tiled screen") if !painted? && @program.walk.any? { |node| node.kind == :camera }
              refuse_backdrops_of_its_own!
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            # A `screen` other than the game's own that says a backdrop the game's does not: a scene's
            # own. Colour 0 is the console's one backdrop, set once for the game, so one that changes
            # as a scene comes up is not made yet.
            def refuse_backdrops_of_its_own!
              game_backdrop = @cache.handover.game_backdrop
              return unless @program.walk.any? { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }

              refuse_unmade!("a scene that says a backdrop of its own (`screen ... backdrop:`)")
            end

            # Reference#exec_fade and #exec_tint, which on a console that cannot blend walk the colours
            # (IR::Fading; PaletteWalk says what the walk is and when it is done, Runtime::Tint does it here).
            def emit_fade(node) = emit_palette_walk(node)
            def emit_tint(node) = emit_palette_walk(node)

            def emit_palette_walk(node)
              return unless tiled? || painted?

              walk = PaletteWalk.walk_for(node)
              runtime_call("rt_tint_to", [Build.int(walk.toward), walk.steps, Build.int(walk.color)])
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
              return unless places_sprites?

              poses = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              return make_art_by_scene(poses) if @scene_tiles

              poses.each { |name| make_sprite_picture(name) }
              @objects.each_value { |obj| recolor_palettes(obj) }
              @backgrounds.each { |bg| bg.every_map.each_index { |which| grid_of(bg, which) } }
            rescue Art::TooManyLists
              raise NotMadeYet.new("The lists of colours this game draws with need more than the four a Genesis holds at " \
                                   "once. The Genesis build keeps each list for the whole game. It does not swap lists " \
                                   "as the game runs yet. To fix this, draw with fewer lists of colours. To step through " \
                                   "many sets of colours, draw the sprites and the background with one list, and change " \
                                   "what it holds with `recolor`: that list keeps one of the four, whatever the sets. Or " \
                                   "build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).", part: "the picture")
            end

            # The sprite picture +name+, made into pieces (Art#sprite_picture) from the tiles of the scene that
            # alone shows it, in a game whose sprite pictures take turns (+scene_tiles+ of :sprites).
            def make_sprite_picture(name)
              image = @cache.image(picture_named(name))
              @art.with_tiles_of(tiles_scene_of_picture(name)) do
                if (list = followed_list_of(name))
                  @art.sprite_picture(name, image, palette: @art.reserve_held_palette([:sprites, list], own_colors(image)))
                elsif recolored?(name)
                  @art.sprite_picture(name, image, palette: @art.ordered_palette(own_colors(image)))
                else
                  @art.sprite_picture(name, image)
                end
              end
            end

            # THE ART OF A GAME WHOSE SCENES EACH KEEP THEIR OWN TILES (Art's +scene_tiles+): what every
            # screen shows made first, so its tiles are numbered before any scene takes its copy, then each
            # scene's own. A tile a `set_tile` can put on a background is made here too, though no map shows
            # it, so it is numbered with its background's tiles rather than after a scene's.
            #
            # WHERE THE SPRITE PICTURES GO. Built with :backgrounds, every sprite picture is one every
            # screen shows, a scene's own included, and stays in video memory for the whole game. The
            # frame a scene takes over on can want a sprite of the scene that went beside the map of the
            # one that came: a dispatch inside an `if` places the pass's sprites for the scene up as the
            # pass started (IR::Frames.loop_in_console_order), while the arriving scene's map is up
            # already. Kept in the room the scenes take turns with, that sprite would be drawn from
            # whatever the arriving scene put there. Built with :sprites, for a game whose sprite
            # pictures do not all fit beside a scene's backgrounds, a scene's own take turns too, and
            # the one way of writing the loop that shows such a frame is refused
            # (#refuse_hand_over_inside_test!).
            def make_art_by_scene(poses)
              refuse_hand_over_inside_test! if @scene_tiles == :sprites
              shared_poses, own_poses = poses.partition { |name| tiles_scene_of_picture(name).nil? }
              shared_backgrounds, own_backgrounds = @backgrounds.partition { |bg| tiles_scene_of(bg).nil? }
              shared_poses.each { |name| make_sprite_picture(name) }
              shared_backgrounds.each { |bg| make_background_art(bg) }
              own_poses.each { |name| make_sprite_picture(name) }
              own_backgrounds.each { |bg| make_background_art(bg) }
              @objects.each_value { |obj| recolor_palettes(obj) }
            end

            # A SCENE PICKED INSIDE A TEST, after the game changed the variable that picks it in the same
            # pass: the frame of that pass shows the scene that was up as the pass started, with its
            # sprites (IR::Frames.loop_in_console_order), while the scene picked has put its own tiles
            # where those sprites' tiles were. A scene picked at the top of the loop is shown with the
            # number it was picked by, and a variable changed after the pick takes effect on the next
            # pass, so either is right.
            def refuse_hand_over_inside_test!
              @program.walk.select { |node| node.kind == :loop }.each do |loop_node|
                loop_node.children.reject { |node| Frames.scene_dispatch?(node) }.flat_map { |node| Frames.dispatches_inside(node) }.each do |dispatch|
                  change = statements_run_before(loop_node, dispatch).find { |node| LightScenes.written_var(node) == dispatch.var && node.kind != :case }
                  next unless change

                  raise LoweringError, hand_over_inside_test_message(dispatch, change)
                end
              end
            end

            def hand_over_inside_test_message(dispatch, change)
              name = dispatch.var
              "The scenes of this game share one area of video memory for their sprite pictures. " \
                "The game changes `#{name}`#{line_words(change)}. Then, in the same pass, it uses `#{name}` " \
                "to pick a scene inside an `if`#{line_words(dispatch)}. On that pass, the sprites of the " \
                "last scene show with the wrong pictures. To fix this, move `case_var(:#{name})` to the top " \
                "of the game loop, outside the `if`. Or change `#{name}` after the `case_var`."
            end

            # " at file.rb:12" for the line that wrote +node+, or the nearest line around it that the
            # build knows; nothing where it knows none.
            def line_words(node)
              node = node.parent while node.source.nil? && node.parent
              node.source ? " at #{node.source}" : ""
            end

            # Every statement a pass of +loop_node+ runs before it reaches +target+, in the order it runs
            # them, with the bodies of the routines they call (not the scenes, which only the pick runs).
            def statements_run_before(loop_node, target)
              ran = []
              collect_statements_before(loop_node.children, target, ran)
              ran
            end

            # Adds to +ran+ what +nodes+ run, in turn, until +target+; true once it is reached.
            def collect_statements_before(nodes, target, ran)
              nodes.each do |node|
                return true if node.equal?(target)

                if node.walk.any? { |inner| inner.equal?(target) }
                  return true if collect_statements_before(node.children, target, ran)

                  next
                end
                node.walk.each { |inner| ran << inner }
                ran.concat(statements_of_routines_called(node))
              end
              false
            end

            # Every statement of the routines +node+ calls, and of those they call, scenes left out.
            def statements_of_routines_called(node, seen = Set.new)
              routines = @routines_by_name ||= @program.walk.select { |func| func.kind == :func }.to_h { |func| [func.name, func] }
              node.walk.flat_map do |inner|
                names = inner.kind == :call_one_of ? inner.targets : [(inner.target if inner.kind == :call)]
                names.compact.reject { |name| Modes.scene_func?(name) || !seen.add?(name) }.flat_map do |name|
                  routine = routines[name]
                  routine ? routine.walk.to_a + statements_of_routines_called(routine, seen) : []
                end
              end
            end

            # Every map of +bg+ as a grid, and every cell a `set_tile` can change it to.
            def make_background_art(bg)
              bg.every_map.each_index { |which| grid_of(bg, which) }
              @program.walk.each do |node|
                next unless node.kind == :set_tile && node.name == bg.name && node.tile && node.tile < bg.tiles.length

                cell_of(bg, node.tile)
              end
            end

            # THE SCENE WHOSE OWN TILES +bg+ IS DRAWN FROM, in a game of +scene_tiles+: the scene it is
            # declared in, which puts it up as it takes over; nil for scenery every screen shows.
            def tiles_scene_of(bg) = @scene_tiles ? scene_owning_background(bg) : nil

            # The same for the sprite picture +name+ (LoweringPlan#scene_showing_picture), when sprite
            # pictures take turns too.
            def tiles_scene_of_picture(name) = @scene_tiles == :sprites ? scene_owning_picture(name) : nil

            def scene_owning_background(bg) = (bg.scene if @handover.on_arrival?(bg) && @scenes.key?(bg.scene))

            def scene_owning_picture(name)
              scene = @plan.scene_showing_picture(name)
              scene if @scenes.key?(scene)
            end

            # WHETHER SOME ART BELONGS TO ONE SCENE, so that bringing each scene's tiles in as it takes over
            # can leave room (Genesis#build). Only in a game of one dispatch: a second variable picking
            # scenes can have one of its scenes up beside one of the first's, and the two would want their
            # own tiles in the same room at once.
            public def art_of_one_scene?
              one_dispatch? && (@backgrounds.any? { |bg| scene_owning_background(bg) } || sprites_of_one_scene?)
            end

            # Whether some sprite picture belongs to one scene, so that its taking turns can leave room.
            public def sprites_of_one_scene?
              one_dispatch? && @objects.values.flat_map(&:poses).any? { |name| scene_owning_picture(name) }
            end

            def one_dispatch? = tiled? && @program.walk.count { |node| node.kind == :case } == 1

            # THE COLOURS A SPRITE CAN BE DRAWN WITH (`draw_with`): every list it names, a palette each whose
            # places are the list's (Art#ordered_palette), and the picture cut into places of its own list, so
            # the sprite is drawn in a list by writing that list's palette's number over the palette its pieces
            # name (Runtime::Tiles, rt_sprite_place). A list the game changes as it runs
            # (`recolor`) keeps a palette that is written over, as the colours it holds change; one that is
            # never changed shares a palette with any other list of the same colours.
            def recolored?(name) = @objects.values.any? { |obj| obj.poses.include?(name) && !obj.recolors.empty? }

            # THE CHANGING LIST A PICTURE IS ALWAYS DRAWN WITH, or nil. A picture every sprite showing it draws
            # with one list the game changes, for good and from power-on (Object#follows), is drawn in that list
            # whatever the list holds, and its own colours are the list's as declared. So it is cut against the
            # list's palette, and keeps no palette for its own colours: a title's sprite and its picture, both
            # drawn with the list, then take one of the four between them.
            def followed_list_of(name)
              lists = @objects.values.select { |obj| obj.poses.include?(name) }.map(&:follows).uniq
              lists.first if lists.length == 1
            end

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
              if backdrop_copied? && backdrop_list.name == node.name
                runtime_call("rt_backdrop_hold", [LabelAddress.new(BACKDROP_COLORS), node.which])
              end
              palette = @art.held_palette_of([:sprites, node.name]) or return

              list = color_list_named(node.name)
              label = held_colors_label([:list, node.name], list.colors, list.recolors)
              runtime_call("rt_colors_hold", [LabelAddress.new(label), node.which, Build.int(palette)])
            end

            # A BACKDROP THAT FOLLOWS A LIST (IR::Nodes::ColorList#backdrop_place). The video chip's register 7
            # says which colour of its memory shows wherever nothing is drawn, any of the sixty-four, so where
            # the list keeps a palette of its own and the backdrop is one of the colours in that palette's
            # places, the register points at it there: the list's write changes the backdrop with everything
            # else drawn from the palette, and nothing is copied (#backdrop_register). A list's first place is
            # its see-through one, which a palette does not keep, and a list nothing is drawn with has no
            # palette at all; there the backdrop stays colour 0 and its colour in the set the list holds is
            # copied in, on the same pass (Runtime::Tint's rt_backdrop_hold).
            BACKDROP_COLORS = "art backdrop colors"

            # The list the backdrop follows, or nil.
            def backdrop_list
              return @backdrop_list if defined?(@backdrop_list)

              @backdrop_list = @program.walk.find { |node| node.kind == :color_list && node.backdrop_place }
            end

            # Where in the colour memory the backdrop is pointed: a place of the list's own palette, or nil.
            def backdrop_pointed_at
              list = backdrop_list
              return nil unless tiled? && list && list.backdrop_place.positive?

              palette = @art.held_palette_of([:sprites, list.name]) or return nil
              (palette * Art::PLACES) + list.backdrop_place
            end

            # Whether the backdrop's colour is copied into colour 0 as the list changes.
            public def backdrop_copied? = tiled? && !backdrop_list.nil? && backdrop_pointed_at.nil?

            # Register 7's value: colour 0 unless the backdrop points into the list's palette.
            def backdrop_register = backdrop_pointed_at || 0

            # The table rt_backdrop_hold reads: how many sets besides the declared colours, then the backdrop's
            # colour in those and in each other set, the game's 15-bit colours.
            def write_backdrop_colors(data)
              return unless backdrop_copied?

              list = backdrop_list
              data.label(BACKDROP_COLORS)
              data.data_words(list.recolors.length)
              data.data_words([list.colors, *list.recolors].map { |set| set.fetch(list.backdrop_place) & 0x7FFF })
            end

            # Reference#exec_background_colors: each list the background's tiles are drawn from holds the list the
            # game's number names for it, the same list for each and the same step through them all. A list no tile
            # is drawn from has no palette, and nothing to show.
            def emit_background_colors(node) = for_background(node) { |bg| emit_background_colors_of(bg, node) }

            # The tiles of a background that follow a list the game changes are drawn from the list's own palette,
            # which the list's write fills (#emit_color_list_holds), so they have nothing of their own to write.
            def emit_background_colors_of(bg, node)
              bg.drawn_lists.each_index do |index|
                next if index == bg.followed_list_index

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
              return [] unless places_sprites?

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
                  data.data_words(piece.dx, piece.dy, (piece.tile + sprite_tiles_from) | (piece.palette << Art::PALETTE_SHIFT),
                                  piece.size_bits)
                end
              end
              write_held_colors(data)
              write_backdrop_colors(data)
              write_colors15(data) if self.class.changing_colors?(@program) && !painted? # a painted screen's is Paint#paint_sections'
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
              scenes = scene_tile_sections(data)
              [data.section, *tile_section, *scenes]
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

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none. Made once
            # for a tile: a map says the same few tiles hundreds of times, and making one reads its 64 pixels.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              @cells_made[[bg.object_id, tile]] ||= begin
                image = @cache.image(picture_named(bg.tiles.fetch(tile)))
                @art.with_tiles_of(tiles_scene_of(bg)) do
                  bg.recolors.empty? ? @art.background_cell(image) : @art.background_cell(image, palette: recolored_palette(bg, image))
                end
              end
            end

            # THE PALETTE A TILE OF A BACKGROUND THE GAME DRAWS WITH OTHER COLOURS IS DRAWN FROM: one for each list
            # its tiles were drawn from, written over with the colours of the list the game's number names for it
            # (Reference#background_swap). The tile is made of the places of its own list.
            #
            # A BACKGROUND THAT FOLLOWS A LIST THE GAME CHANGES (`recolor`) draws the tiles drawn from that list
            # from the list's palette, the one its sprites are drawn from; a cell's palette is its own, so tiles of
            # its other lists beside them keep palettes of their own at no cost. A Genesis keeps one table of colours for its backgrounds and its
            # sprites together, four palettes of sixteen, so a title whose picture and sprites step through any
            # number of sets of colours costs one palette, written over in the blank, and leaves three for the rest.
            #
            # A LIST THAT HOLDS THE SAME COLOURS WHATEVER THE GAME SAYS needs no writing over: a background told
            # `draw_with :machine` and drawn in :machine's own colours shows those colours at every step. So its
            # palette is the list's in the list's order (Art#ordered_palette), which a sprite drawn with the
            # same list shares, rather than one kept to itself. Only place 0 may differ between the sets, since
            # it is see-through and no palette keeps it.
            def recolored_palette(bg, image)
              list = bg.recolored_list_of(image.list_drawn_from) or
                raise LoweringError, "a tile of the background #{bg.name.inspect} is drawn from a list of colours it was not given"
              index = bg.drawn_lists.index(list)
              colors = bg.palettes.fetch(index).drop(1).map { |color| color & 0x7FFF }
              followed = index == bg.followed_list_index
              return @art.ordered_palette(colors) if !followed && unchanging_colors?(bg, index, colors)

              key = followed ? [:sprites, bg.follows] : [:background, bg.object_id, index]
              @art.reserve_held_palette(key, colors)
            end

            # Whether every set +bg+'s list number +index+ can be drawn with holds +colors+ (its own, place 0
            # left out) at the same places.
            def unchanging_colors?(bg, index, colors)
              bg.recolors.all? { |step| step.fetch(index).drop(1).map { |color| color & 0x7FFF } == colors }
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
              return if painted?

              emit_scene_tiles(scene)
              return if @scene_layers.zero?

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

            # A SCENE TAKING OVER, in a game of +scene_tiles+: its own tiles go into video memory over the last
            # scene's, in the blank at the end of this pass (Runtime::Tiles' rt_scene_tiles). The pass is its
            # own with `loads_first:`, and shared with the scene's first pass of game without.
            def emit_scene_tiles(scene)
              return unless @scene_tiles

              runtime_call("rt_scene_tiles", [LabelAddress.new(scene_tiles_table_label(scene))])
            end

            def scene_tiles_table_label(scene) = "art scene tiles table #{scene}"
            def scene_tiles_label(scene) = "art scene tiles #{scene}"

            # For each scene, the table rt_scene_tiles reads, written once every tile is made: where its own
            # tiles are on the cartridge (nought for a scene with none), how many long words they are, and
            # where in video memory they go; and the tiles themselves, a section each.
            def scene_tile_sections(data)
              return [] unless @scene_tiles

              at = @art.first_scene_tile * Art::TILE_BYTES
              @scenes.keys.filter_map do |scene|
                bytes = @art.scene_tile_data(scene)
                data.label(scene_tiles_table_label(scene))
                data.data_longs(bytes.empty? ? 0 : scene_tiles_label(scene), bytes.bytesize / 4, at)
                next if bytes.empty?

                asm = M68000.new(scene_tiles_label(scene), holds: ART)
                asm.label(scene_tiles_label(scene))
                asm.data_bytes(bytes.bytes)
                asm.section
              end
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
              return unless places_sprites?

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
            #
            # The entry picks its routine from a table of their addresses, a long each, kept beside
            # the code: four instructions an entry, whatever the run's length. Asking each entry "is
            # it the first? the second?..." in turn would cost every entry a test for each sprite
            # before it, so the whole run a test for every pair of its sprites.
            def emit_ordered_run(run)
              table = fresh("ordered_placings")
              past = fresh("past_ordered_placings")
              @asm.bra(past)
              @asm.label(table)
              @asm.data_longs(run.objects.map { |name| sprite_placing_label(name) })
              @asm.label(past)
              outside = fresh("order_outside") unless @lists_dropped_from_front.include?(run.order)
              run.objects.each_index do |k|
                outside ? emit_order_entry_read(run.order, k, outside) : value(Build.list_get(run.order, Build.int(k)))
                @asm.lsl(:l, 2, @asm.d(0))
                @asm.lea(@asm.abs_l(table), @asm.a(0))
                @asm.movea(:l, @asm.idx(0, 0, 0), @asm.a(0))
                @asm.jsr(@asm.ind(0))
              end
              emit_order_index_fault(run.order, outside) if outside
            end

            # D0 = entry +k+ of the order list +order+, whose first item is in its first slot, read from
            # its slot's address: the index tested against how many the list holds (D1 = +k+ for the
            # fault at +outside+), where reading it through the runtime would take a call, and the
            # list's place found and the index scaled there. The entry is a place in the run, never
            # below nought.
            def emit_order_entry_read(order, k, outside)
              place, _capacity, bytes = @lists.fetch(order)
              k.between?(-128, 127) ? @asm.moveq(k, @asm.d(1)) : @asm.move(:l, @asm.imm(k), @asm.d(1))
              @asm.cmp(:w, @asm.abs_l(place, Runtime::Lists::LENGTH), @asm.d(1))
              @asm.branch(:cc, outside)
              @asm.moveq(0, @asm.d(0)) unless bytes == 4
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), @asm.abs_l(place, Runtime::Lists::HEADER + (k * bytes)), @asm.d(0))
            end

            # The run's entry D1 was outside the order list: the game stopped as the runtime stops it
            # (Runtime::Lists#emit_faults), past the code the run's entries go on to.
            def emit_order_index_fault(order, outside)
              past = fresh("order_inside")
              @asm.bra(past)
              @asm.label(outside)
              @asm.move(:l, @asm.imm(@lists.fetch(order).first), @asm.d(0))
              @asm.movea(:l, @asm.d(0), @asm.a(0))
              @asm.jmp(@asm.abs_l("rt_list_index_fault"))
              @asm.label(past)
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
