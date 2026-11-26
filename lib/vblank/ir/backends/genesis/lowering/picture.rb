# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # The picture of a tiled screen, lowered for a Genesis: the statements that draw, as calls
          # into Runtime::Picture, and the game's pictures made into tiles, palettes and maps (Genesis::Art)
          # while the program is built. Mixed into Lowering.
          #
          # A tiled screen. Each background the game declares is given one of the console's two planes, the
          # one declared last in front (plane A), as the interpreter paints the one declared last over the
          # rest. Each map it can show is made into a grid of cells, kept whole in the cartridge and
          # copied onto its plane when it is put up. Each sprite is made of the console's 8×8 sprite
          # pieces, placed in the sprite table every pass the game places its sprites.
          module Picture
            STATEMENT_KINDS = %i[
              background scroll_background set_tile set_tile_block show_map present_objects color_list_holds
              background_colors fade tint hide_sprites scroll_rows
            ].freeze

            def emit_picture_statement(node)
              case node.kind
              when :background then emit_background(node)
              when :scroll_background then emit_scroll_background(node)
              when :set_tile then emit_set_tile(node)
              when :set_tile_block then emit_set_tile_block(node)
              when :show_map then emit_show_map(node)
              when :present_objects then emit_present_objects(node)
              when :color_list_holds then emit_color_list_holds(node)
              when :background_colors then emit_background_colors(node)
              when :fade then emit_fade(node)
              when :tint then emit_tint(node)
              when :hide_sprites then emit_hide_sprites(node)
              when :scroll_rows then emit_scroll_rows(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # The Genesis::Art the game's pictures were made into.
            attr_reader :art

            # The sprite table has this many rows (Console::Description#sprites).
            MOST_SPRITES = Console::GENESIS.sprites

            # The two planes a background can be on: plane A is in front.
            PLANES = 2

            def prepare_picture
              @art = Art.new(backdrop: @cache.handover.game_backdrop, exact: self.class.fading?(@program),
                             beside_painting: painted?, scene_tiles: @scene_tiles, scene_colors: @scene_colors)
              @objects = by_kind(:object)
              @backgrounds = @program.walk.select { |node| node.kind == :background }
              @sprite_names = SpriteNames.new(@program)
              @grids = {}
              @cells_made = {}
              @pose_tables = {}
              @front_pose_tables = {} # the same for the sprites drawn in front (#pose_table)
              @pose_rooms = {}
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
              refuse_backdrops_of_its_own!
              refuse_unmade_backgrounds!
              refuse_unmade_sprites!
            end

            # A `screen` other than the game's own that says a backdrop the game's does not, somewhere
            # it cannot come up by: on a painted screen, or anywhere but one of a scene's own lines.
            def refuse_backdrops_of_its_own!
              handover = @cache.handover
              game_backdrop = handover.game_backdrop
              said = @program.walk.select { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }
              return if said.empty? || (!painted? && said.all? { |node| handover.scene_screen?(node) })

              refuse_unmade!("a `screen ... backdrop:` of its own on a painted screen, or anywhere but in a scene's own lines")
            end

            # Whether a scene of +program+ says a backdrop the game's does not, which colour 0 is changed
            # to as it takes over (Runtime::Tint's rt_scene_backdrop).
            def self.scene_backdrops?(program, handover = IR::SceneHandover.of(program))
              return false if Lowering::Paint.painted?(program)

              handover.scene_screens.any? { |_, screen| screen.backdrop && screen.backdrop != handover.game_backdrop }
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

            # Which of the two planes each background is on. A scene's own scenery is in front of the scenery every
            # screen shows, as the interpreter paints it over what is up already, and within each the one drawn
            # last is in front (IR::Stacking, which IR::SceneHandover hands the scenery over in the order of): so
            # the scenes' own take the front planes, A first, as many as the scene with the most has, and the
            # scenery every screen shows the planes behind those. So a stack that puts a scene's own background
            # behind one every screen shows is not made yet.
            def assign_background_layers
              always = @handover.always_up.scenery
              own = @scenes.keys.map { |scene| @handover.arrival(scene).scenery }
              @scene_layers = own.map(&:length).max || 0
              @plan.refuse_unmade_stacking!(NotMadeYet, part: "the picture")
              always.each_with_index { |bg, i| @layers[bg] = @scene_layers + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
            end

            def layer_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no plane" }

            def refuse_unmade!(what)
              raise NotMadeYet.new("This game has #{what}. The Genesis build does not make that yet. To fix this, " \
                                   "build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "the picture")
            end

            # Every picture a sprite can show, made into sprite pieces in the order SpriteNames numbers
            # them, so the number a picture is made with is the one a reader of the drawn sprites turns
            # back into its name. A picture only sprites kept to one pose show is drawn from their rooms
            # alone (PoseRooms#make_pose_rooms), and is not kept in video memory whole.
            def make_sprite_art
              return unless places_sprites?

              poses = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              kept_whole = @objects.values.reject { |obj| streamed?(obj) }.flat_map(&:poses).uniq
              refuse_hand_over_inside_test!(:colors) if sprite_colors_take_turns?
              allot_shared_colors(poses) if @scene_colors
              make_pose_rooms
              poses &= kept_whole
              return make_art_by_scene(poses) if @scene_tiles

              make_sprite_pictures(poses)
              @objects.each_value { |obj| recolor_palettes(obj) }
              @backgrounds.each { |bg| bg.every_map.each_index { |which| grid_of(bg, which) } }
            rescue Art::TooManyLists => e
              raise if scene_colors_after(@scene_colors) || remap_helps?

              raise NotMadeYet.new(too_many_lists_message(e), part: "the picture")
            rescue Art::TooManyColors
              raise unless @remapped_lists && !scene_colors_after(@scene_colors) && (words = remapped_colors_message)

              raise Art::TooManyColors, words
            end

            # The words for sprites whose copies in each list's colours (#remapped?) did not fit beside the
            # other pictures: the sprite whose copies found no palette, and how many colours its lists hold.
            # Nil where the copies are not what overflowed, so the refusal keeps the words it was raised with.
            def remapped_colors_message
              obj = @copies_overflowed or return nil
              count = @remap_reserved.fetch(obj)

              name = obj.declared || obj.name
              "The sprite :#{name} is drawn with #{obj.recolors.length} lists of colours (`draw_with`). The Genesis " \
                "build makes a copy of the picture for each list, in the colours of that list. The copies and the " \
                "other pictures use more colours than a Genesis can show. A Genesis holds #{Art::PALETTES} sets of " \
                "#{Art::OWN_COLORS} colours for the backgrounds and sprites together. #{remapped_count_words(name, count)}"
            end

            # What the refusal (#remapped_colors_message) says of the +count+ colours of the sprite +name+'s lists.
            def remapped_count_words(name, count)
              if count > Art::OWN_COLORS
                return "The lists and the picture of :#{name} hold #{count} different colours. If they hold " \
                       "#{Art::OWN_COLORS} or fewer, all the copies use one set. To fix this, use fewer colours in " \
                       "the lists, or draw the sprite with fewer lists."
              end

              "The lists and the picture of :#{name} hold #{count} different colours, and they use one set. The " \
                "other pictures leave no set for them. To fix this, use fewer colours in the other pictures."
            end

            # The words for lists of colours that did not fit, the game's (+error+ names no scene) or one scene's.
            def too_many_lists_message(error)
              advance = "Or build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`)."
              if error.scene
                return "#{error.message} The Genesis build keeps each list for the whole time its scene is up. It does not " \
                       "swap lists as the game runs yet. To fix this, draw the pictures of that scene with fewer lists of " \
                       "colours. #{advance}"
              end

              "The lists of colours this game draws with need more than the four a Genesis holds at once. Short lists " \
                "of a background share one of the four, and these lists do not fit even so. The Genesis " \
                "build keeps each list for the whole game. It does not swap lists as the game runs yet. To fix this, draw " \
                "with fewer lists of colours. To step through many sets of colours, draw the sprites and the background " \
                "with one list, and change what it holds with `recolor`: that list keeps one of the four, whatever the " \
                "sets. #{advance}"
            end

            # The sprite pictures +names+, made into pieces, each from the tiles of the scene that alone shows
            # it in a game whose sprite pictures take turns (+scene_tiles+ of :sprites). Every one is cut
            # first, in the order given, which is the order their colours take palettes in. Then, for the
            # pictures that share a room of video memory, the runs of tiles their pieces name go in the
            # longest first (Art#store_piece_runs_longest_first), and each picture is given its tiles.
            #
            # The copies of each in the colours of each list a sprite is drawn with (#remapped?) are made
            # after them, from the same scene's tiles and colours.
            def make_sprite_pictures(names)
              names += remapped_keys_of(names)
              names.each { |name| cut_sprite_picture(name) }
              names.group_by { |name| tiles_scene_of_picture(pose_of(name)) }.each do |scene, together|
                @art.with_tiles_of(scene) { @art.store_piece_runs_longest_first(together) }
              end
              names.each { |name| @art.with_tiles_of(tiles_scene_of_picture(pose_of(name))) { @art.sprite_picture(name) } }
            end

            # The sprite picture +name+ cut into pieces (Art#cut_sprite_picture), from the palette it is drawn from:
            # one of its scene's own, in a game whose sprite colours take turns (#colors_scene_of_picture).
            # +name+ can be a Remapped copy of a picture too.
            def cut_sprite_picture(name)
              return cut_remapped_picture(name) if name.is_a?(Remapped)

              image = @cache.image(picture_named(name))
              @art.with_colors_of(colors_scene_of_picture(name)) do
                remapped_showing(name).each { |obj| reserve_remapped_colors(obj) }
                if (list = followed_list_of(name))
                  @art.cut_sprite_picture(name, image, palette: @art.reserve_held_palette([:sprites, list], own_colors(image)))
                elsif recolored?(name) || follows_unchanging_list?(name)
                  @art.cut_sprite_picture(name, image, palette: @art.ordered_palette(own_colors(image)))
                elsif pictures_in_list_order? && (list = list_order_of(name))
                  @art.cut_sprite_picture(name, image, palette: @art.ordered_palette(own_colors(image), taker: "the list of colours :#{list}"))
                else
                  @art.cut_sprite_picture(name, image)
                end
              end
            end

            # The colours every screen keeps, in a game whose scenes each keep their own colours (Art's
            # +scene_colors+): allotted before any scene takes its copy of the palettes. First the palette of
            # every list the game changes, which is written over whichever scene is up, and the lists the
            # sprites are drawn with; then the colours of the sprite pictures and the backgrounds every screen
            # shows. A scene's own pictures are made after, each from its scene's copy.
            def allot_shared_colors(poses)
              scene_held = lists_take_turns? ? scene_held_lists : {}
              poses.each do |name|
                list = followed_list_of(name)
                next unless list && !scene_held.key?([:sprites, list])

                @art.reserve_held_palette([:sprites, list], own_colors(@cache.image(picture_named(name))))
              end
              later, now = @objects.values.partition { |obj| object_draws_with_scene_held_list?(obj, scene_held) }
              now.each { |obj| recolor_palettes(obj) }
              @backgrounds.each do |bg|
                bg.tiles.uniq.each do |tile|
                  palette = held_list_palette_of_tile(bg, tile) or next
                  next unless palette.key && !scene_held.key?(palette.key)

                  @art.reserve_held_palette(palette.key, palette.colors, name: palette.name)
                end
              end
              poses.each { |name| cut_sprite_picture(name) unless colors_scene_of_picture(name) }
              @backgrounds.each { |bg| make_background_art(bg) unless colors_scene_of(bg) }
              scene_held.each { |key, held| @art.reserve_scene_held_palette(key, held.colors, held.scenes, name: held.name) }
              later.each { |obj| @art.with_colors_of(object_scene(obj)) { recolor_palettes(obj) } }
            end

            # The palette of a list the game changes that the tile +tile+ of +bg+ is drawn from (#list_palette_of),
            # or nil for a tile drawn in its own colours.
            def held_list_palette_of_tile(bg, tile)
              image = run_painting(tile) || @cache.image(picture_named(tile)) # a run answers list_drawn_from as a picture does
              return nil if bg.recolors.empty? && bg.list_followed_by(image.list_drawn_from).nil?

              list_palette_of(bg, image)
            end

            # The scene whose own colours +bg+ is drawn in, in a game of +scene_colors+: the scene it is declared
            # in, which puts it up as it takes over; nil for scenery every screen shows.
            def colors_scene_of(bg) = @scene_colors ? scene_owning_background(bg) : nil

            # The same for the sprite picture +name+, when sprite colours take turns too (+scene_colors+ of
            # :sprites or :lists).
            def colors_scene_of_picture(name) = sprite_colors_take_turns? ? scene_owning_picture(name) : nil

            def sprite_colors_take_turns? = %i[sprites lists list_order].include?(@scene_colors)
            def lists_take_turns? = %i[lists list_order].include?(@scene_colors)
            def pictures_in_list_order? = @scene_colors == :list_order

            # The list a picture is drawn in its order from, built with :list_order: the list of colours the
            # picture was declared with (`colors:`, or the bank of a data pack's colours its frame names),
            # where that list fits a palette. A console game draws each piece from the palette line its frame
            # names, a line holding one bank of colours in the bank's order. Packed by their colours, pictures
            # of three banks can need more than three palettes, the colours of one picture spread over two;
            # in their lists' order, they need one palette for each list, and every picture of one list shares it.
            # Nil for a picture drawn in no list.
            def pictures_in_lists? = @objects.values.flat_map(&:poses).uniq.any? { |name| list_order_of(name) }

            def list_order_of(name)
              list = picture_named(name).colors_name or return nil
              list if own_colors(@cache.image(picture_named(name))).length <= Art::OWN_COLORS
            end

            # The +scene_colors+ to build with after a build with +tried+ ran out of palettes (Genesis#build),
            # or nil when nothing is left to try: :backgrounds, each scene's own backgrounds in palettes of its
            # own while it is up, every sprite picture's colours kept for the whole game; then :sprites, a
            # scene's own sprite pictures' colours taking turns too; then :lists, a list the game changes that
            # only some scenes draw with keeping its palette in those scenes alone (#scene_held_lists); then
            # :list_order, each picture declared with a list cut against a palette of that list (#list_order_of). Only
            # in a game of one dispatch, as tiles are (#art_of_one_scene?), and a step that would change
            # nothing is passed over.
            public def scene_colors_after(tried)
              backgrounds = one_dispatch? && @backgrounds.any? { |bg| scene_owning_background(bg) }
              steps = [(:backgrounds if backgrounds), (:sprites if sprites_of_one_scene?),
                       (:lists if one_dispatch? && !scene_held_lists.empty?),
                       (:list_order if one_dispatch? && pictures_in_lists?)].compact
              return steps.first unless tried

              steps[steps.index(tried) + 1] if steps.include?(tried)
            end

            # A list the game changes whose palette only some scenes keep: the colours it starts with (15-bit,
            # see-through left out), those scenes, and what a refusal calls it (ListPalette's +name+).
            SceneHeldList = Data.define(:colors, :scenes, :name)

            # Every list the game changes that only some scenes draw with, by the key its palette is kept under
            # (Art#reserve_held_palette): the lists every sprite picture, sprite and background drawing with it
            # belongs to a scene of, with those scenes. A scene that draws nothing with such a list needs nothing
            # of its palette, so built with :lists every other scene has that palette for its own pictures
            # (Art#reserve_scene_held_palette). A list anything every screen shows draws with is kept for every
            # scene, as before. A sprite belongs to a scene when every pose it shows does.
            def scene_held_lists
              @scene_held_lists ||= begin
                found = {}
                drawn = lambda do |key, colors, scene, name = nil|
                  (found[key] ||= SceneHeldList.new(colors: colors, scenes: [], name: name)).scenes << scene
                end
                @objects.values.flat_map(&:poses).uniq.each do |name|
                  list = followed_list_of(name)
                  drawn.call([:sprites, list], own_colors(@cache.image(picture_named(name))), scene_owning_picture(name)) if list
                end
                @objects.each_value do |obj|
                  changing_lists_of(obj).each { |entry, colors| drawn.call([:sprites, entry], colors, object_scene(obj, owned: true)) }
                end
                @backgrounds.each do |bg|
                  bg.tiles.uniq.each do |tile|
                    palette = held_list_palette_of_tile(bg, tile)
                    drawn.call(palette.key, palette.colors, scene_owning_background(bg), palette.name) if palette&.key
                  end
                end
                found.reject { |_, held| held.scenes.include?(nil) }
                     .transform_values { |held| held.with(scenes: held.scenes.uniq.sort_by { |scene| @scenes.fetch(scene) }) }
              end
            end

            # The lists the game changes that +obj+ can be drawn with (`draw_with`, `recolor`), each with the
            # colours it starts with.
            def changing_lists_of(obj)
              obj.recolors.filter_map do |entry|
                next unless entry.is_a?(Symbol)

                list = color_list_named(entry)
                [entry, list.colors.drop(1).map { |color| color & 0x7FFF }] unless list.recolors.empty?
              end
            end

            # The scene every pose of +obj+ belongs to, or nil where they do not all belong to one. +owned+ asks
            # it of the scenes the poses belong to, whatever the build; without it, of the scenes whose colours
            # the poses are cut in (#colors_scene_of_picture).
            def object_scene(obj, owned: false)
              scenes = obj.poses.map { |name| owned ? scene_owning_picture(name) : colors_scene_of_picture(name) }.uniq
              scenes.first if scenes.length == 1
            end

            # Whether +obj+ can be drawn with a list of +scene_held+, whose palettes are allotted after those
            # every screen keeps: so its table of palettes is made then too, in its scene's copy.
            def object_draws_with_scene_held_list?(obj, scene_held)
              changing_lists_of(obj).any? { |entry, _| scene_held.key?([:sprites, entry]) }
            end

            # The art of a game whose scenes each keep their own tiles (Art's +scene_tiles+): what every
            # screen shows made first, so its tiles are numbered before any scene takes its copy, then each
            # scene's own. A tile a `set_tile` can put on a background is made here too, though no map shows
            # it, so it is numbered with its background's tiles rather than after a scene's.
            #
            # Where the sprite pictures go. Built with :backgrounds, every sprite picture is one every
            # screen shows, a scene's own included, and stays in video memory for the whole game. The
            # frame a scene takes over on can want a sprite of the scene that went beside the map of the
            # one that came: a dispatch inside an `if` places the pass's sprites for the scene up as the
            # pass started (IR::Frames.loop_in_console_order), while the arriving scene's map is up
            # already. Kept in the room the scenes take turns with, that sprite would be drawn from
            # whatever the arriving scene put there. Built with :sprites, for a game whose sprite
            # pictures do not all fit beside a scene's backgrounds, a scene's own take turns too, and
            # the ways of writing the loop that show such a frame are refused
            # (#refuse_hand_over_inside_test!).
            def make_art_by_scene(poses)
              refuse_hand_over_inside_test!(:pictures) if @scene_tiles == :sprites
              shared_poses, own_poses = poses.partition { |name| tiles_scene_of_picture(name).nil? }
              shared_backgrounds, own_backgrounds = @backgrounds.partition { |bg| tiles_scene_of(bg).nil? }
              make_sprite_pictures(shared_poses)
              shared_backgrounds.each { |bg| make_background_art(bg) }
              make_sprite_pictures(own_poses)
              own_backgrounds.each { |bg| make_background_art(bg) }
              @objects.each_value { |obj| recolor_palettes(obj) }
            end

            # A scene picked inside a test, after the game changed the variable that picks it in the same
            # pass: the frame of that pass shows the scene that was up as the pass started, with its
            # sprites (IR::Frames.loop_in_console_order), while the scene picked has put its own tiles
            # where those sprites' tiles were. A scene picked at the top of the loop is shown with the
            # number it was picked by, and a variable changed after the pick takes effect on the next
            # pass, so either is right.
            #
            # The same is so of a game whose scenes write their own sprite colours as they take over
            # (+scene_colors+ of :sprites): the leaving scene's sprites would be drawn in the arriving
            # scene's palettes. +shared+ names what the scenes take turns with, a key of TAKING_TURNS.
            #
            # A timer moves on at each wait for the screen (Reference#accrue_timer, Runtime::Frame's
            # rt_wait_vblank). The loop's own wait ends the pass, after the frame's sprites are placed, so
            # a timer's change there is noted with the next pass. A wait the pass reaches before the pick,
            # in a routine it calls, lets the timer change the variable after it was noted.
            #
            # A pick after the loop's own wait, written partway down the loop, comes after the end of the
            # pass that places the frame's sprites, so the first frame places the first scene's sprites
            # before that scene has put its tiles in; refused wherever it is in the loop.
            def refuse_hand_over_inside_test!(shared)
              @program.walk.select { |node| node.kind == :loop }.each do |loop_node|
                refuse_pick_after_wait!(loop_node, shared)
                loop_node.children.reject { |node| Frames.scene_dispatch?(node) }.flat_map { |node| Frames.dispatches_inside(node) }.each do |dispatch|
                  ran = statements_run_before(loop_node, dispatch)
                  change = ran.find { |node| writes_scene_number?(node, dispatch.var) }
                  raise LoweringError, hand_over_inside_test_message(dispatch, change, shared) if change

                  wait = ran.find { |node| node.kind == :wait_vblank }
                  timer_change = wait && timer_write_of(dispatch.var)
                  raise LoweringError, timer_across_wait_message(dispatch, timer_change, wait, shared) if timer_change
                end
              end
            end

            def writes_scene_number?(node, var) = LightScenes.written_var(node) == var && node.kind != :case

            # The first write of +var+ a timer's handler makes, in it or a routine it calls, with the timer's
            # name; nil when none does.
            def timer_write_of(var)
              Nodes::OnTimer.of(@program).each do |timer, handler|
                statements = handler.walk.to_a + statements_of_routines_called(handler)
                change = statements.find { |node| writes_scene_number?(node, var) }
                return [timer, change] if change
              end
              nil
            end

            # Refuses a scene picked in a statement of +loop_node+ that runs after the end of the pass, which
            # the console's order puts before the loop's own wait (IR::Frames.loop_in_console_order).
            def refuse_pick_after_wait!(loop_node, shared)
              order = @plan.console_loop(loop_node)
              return if order.pass_end.empty?

              pass_end_at = order.each_time.index { |node| node.equal?(order.pass_end.first) }
              wait = order.each_time[pass_end_at..].find { |node| node.kind == :wait_vblank }
              order.each_time[pass_end_at..].each do |statement|
                dispatch = Frames.dispatches_inside(statement).first
                raise LoweringError, pick_after_wait_message(dispatch, wait, shared) if dispatch
              end
            end

            # What the scenes of a game take turns with, as a refusal words it: what they share, and what the
            # leaving scene's sprites would show wrong.
            TakingTurns = Data.define(:shared, :shown_wrong)
            TAKING_TURNS = {
              pictures: TakingTurns.new(shared: "one area of video memory for their sprite pictures", shown_wrong: "pictures"),
              colors: TakingTurns.new(shared: "the same sets of colours for their sprites", shown_wrong: "colours")
            }.freeze

            def hand_over_inside_test_message(dispatch, change, shared)
              name = dispatch.var
              turns = TAKING_TURNS.fetch(shared)
              "The scenes of this game share #{turns.shared}. " \
                "The game changes `#{name}`#{line_words(change)}. Then, in the same pass, it uses `#{name}` " \
                "to pick a scene inside an `if`#{line_words(dispatch)}. On that pass, the sprites of the " \
                "last scene show with the wrong #{turns.shown_wrong}. To fix this, move the line that picks the scene by `#{name}` to the top " \
                "of the game loop, outside the `if`. Or change `#{name}` after that line."
            end

            def timer_across_wait_message(dispatch, (timer, change), wait, shared)
              name = dispatch.var
              turns = TAKING_TURNS.fetch(shared)
              "The scenes of this game share #{turns.shared}. " \
                "The timer `#{timer}` changes `#{name}`#{line_words(change)}. A timer moves on each time " \
                "the game waits for the screen. The game waits for the screen#{line_words(wait)}, and then, " \
                "in the same pass, it uses `#{name}` to pick a scene inside an `if`#{line_words(dispatch)}. On that pass, the " \
                "sprites of the last scene can show with the wrong #{turns.shown_wrong}. To fix this, move the line that picks the scene by `#{name}` to " \
                "the top of the game loop, outside the `if`. Or change `#{name}` in the game loop, not in the timer."
            end

            def pick_after_wait_message(dispatch, wait, shared)
              name = dispatch.var
              turns = TAKING_TURNS.fetch(shared)
              "The scenes of this game share #{turns.shared}. " \
                "The game uses `#{name}` to pick a scene#{line_words(dispatch)}, after `wait_vblank`#{line_words(wait)} in the " \
                "game loop. The sprites of a pass show before the pass picks its scene, so on the first pass the sprites " \
                "show with the wrong #{turns.shown_wrong}. To fix this, move the line that picks the scene by `#{name}` above `wait_vblank`."
            end

            # " at file.rb:12" for the line that wrote +node+, or the nearest line around it that the
            # build knows; nothing where it knows none.
            def line_words(node)
              node = node.parent while node.source.nil? && node.parent
              node.source ? " at #{node.source}" : ""
            end

            # Every statement a pass of +loop_node+ runs before it reaches +target+, in the order the console
            # runs them (LoweringPlan#console_loop: a wait at the top of the loop ends the pass), with the
            # bodies of the routines they call (not the scenes, which only the pick runs).
            def statements_run_before(loop_node, target)
              ran = []
              collect_statements_before(@plan.console_loop(loop_node).each_time, target, ran)
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
                next unless node.kind == :set_tile && node.name == bg.name

                node.tiles_named.each { |tile| cell_of(bg, tile) if tile && tile < bg.tiles.length }
              end
            end

            # The scene whose own tiles +bg+ is drawn from, in a game of +scene_tiles+: the scene it is
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

            # Whether some art belongs to one scene, so that bringing each scene's tiles in as it takes over
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

            # The +scene_tiles+ to build with after a build with +tried+ ran out of tiles (Genesis#build),
            # or nil when nothing is left to try: :backgrounds, then :sprites.
            public def scene_tiles_after(tried)
              case tried
              when false then :backgrounds if art_of_one_scene?
              when :backgrounds then :sprites if sprites_of_one_scene?
              end
            end

            # A try sure to run out of tiles stops before its code is made. Every picture's tiles are
            # in video memory's list by then but those a `set_tile` names in a game whose scenes share
            # their tiles, made as its code is, and those only add to the count. So a count past the
            # room now is past it at the end. Only where a later try can help: a game nothing can help
            # is refused at the end (Art#refuse_too_many_tiles!), where its count is whole.
            def refuse_tiles_past_room_early!
              return unless places_sprites? && @art.too_many_tiles?

              @art.refuse_too_many_tiles! if scene_tiles_after(@scene_tiles) || streamed_after(@streamed)
            end

            def one_dispatch? = tiled? && @program.walk.count { |node| node.kind == :case } == 1

            # The colours a sprite can be drawn with (`draw_with`): every list it names, a palette each whose
            # places are the list's (Art#ordered_palette), and the picture cut into places of its own list, so
            # the sprite is drawn in a list by writing that list's palette's number over the palette its pieces
            # name (Runtime::Tiles, rt_sprite_place). A list the game changes as it runs
            # (`recolor`) keeps a palette that is written over, as the colours it holds change; one that is
            # never changed shares a palette with any other list of the same colours.
            def recolored?(name)
              @objects.values.any? { |obj| obj.poses.include?(name) && !obj.recolors.empty? && !remapped?(obj) }
            end

            # A copy of the picture +pose+ in the colours +colors+ of a list a sprite is drawn with (a list's
            # whole colours, place 0 first), made ahead of time (#remapped?).
            Remapped = Data.define(:pose, :colors)

            # A palette for each list a sprite is drawn with is the way that costs no tiles, and a Genesis
            # has four palettes (plutiedev, "Palettes"; Sega's Genesis Software Manual, "CRAM"). A sprite
            # drawn with more lists than that, or beside pictures that leave too few, is drawn the other
            # way the hardware allows: a sprite entry names a tile and a palette (Art::Piece), so a copy of
            # the picture whose tiles name, at each pixel, where its list's colour is in some palette draws
            # that list's colours from it. So the build makes such a copy of each of the sprite's poses for
            # each list (Assets::RecoloredImage, Reference's rule: by place), and where the colours of every
            # copy fit one palette, they share it (Art#reserve_sprite_colors). The sprite shows the copies of
            # the list it is told, read from a table of its pose tables (#emit_remapped_pose_table), and a
            # number naming none of its lists shows its own colours, as the interpreter draws it.
            #
            # Only a game that does not fit the first way is built this way (+remapped_lists+, Genesis#build):
            # the copies cost tiles that a palette for each list does not.
            def remapped?(obj) = @remapped_lists && remappable?(obj)

            # Whether +obj+ can be drawn from copies (#remapped?): every list it is drawn with is one the game
            # never changes, since a copy holds the colours as they are when the game is built. A sprite kept
            # to one pose in video memory (#streamed?) copies its poses in from the cartridge itself, and a
            # pose that follows a list keeps that list's palette.
            def remappable?(obj)
              return false if obj.recolors.empty? || streamed?(obj)
              return false unless obj.recolors.all? { |entry| !entry.is_a?(Symbol) || color_list_named(entry).recolors.empty? }

              obj.poses.none? { |name| followed_list_of(name) }
            end

            # Whether a build drawing sprites from copies (#remapped?) could fit where this one did not.
            public def remap_helps? = !@remapped_lists && @objects.values.any? { |obj| remappable?(obj) }

            # The colours, place 0 first, of a list a sprite is drawn with: +entry+ names a list or is the colours.
            def colors_of_entry(entry) = entry.is_a?(Symbol) ? color_list_named(entry).colors : entry

            # The picture a pose's copy is made from, or the pose itself.
            def pose_of(name) = name.is_a?(Remapped) ? name.pose : name

            # The sprites drawn from copies that show the picture +name+.
            def remapped_showing(name) = @objects.values.select { |obj| obj.poses.include?(name) && remapped?(obj) }

            # The copies (Remapped) of the pictures +names+ for each sprite drawn from copies.
            def remapped_keys_of(names)
              @objects.values.select { |obj| remapped?(obj) }.flat_map do |obj|
                obj.recolors.flat_map do |entry|
                  (obj.poses & names).map { |pose| Remapped.new(pose: pose, colors: colors_of_entry(entry)) }
                end
              end.uniq
            end

            def remapped_image(key)
              image = @cache.image(picture_named(key.pose))
              Assets::RecoloredImage.new(image: image, recolor: Assets::Recolor.of(image, key.colors))
            end

            # A copy cut, from the palette that holds its colours. A copy whose colours find no palette is
            # noted with its sprite, so the refusal names the copies only when they are what overflowed
            # (#remapped_colors_message).
            def cut_remapped_picture(key)
              @art.with_colors_of(colors_scene_of_picture(key.pose)) do
                remapped_showing(key.pose).each { |obj| reserve_remapped_colors(obj) }
                @art.cut_sprite_picture(key, remapped_image(key), shows: key.pose)
              rescue Art::TooManyColors
                @copies_overflowed ||= remapped_showing(key.pose).first
                raise
              end
            end

            # One palette for every colour the poses of +obj+ and all their copies draw, where those fit one
            # (Art#reserve_sprite_colors), once for each sprite, before any of them is cut. How many colours
            # those are is kept for a refusal's words (#remapped_colors_message).
            def reserve_remapped_colors(obj)
              @remap_reserved ||= {}
              return if @remap_reserved.key?(obj)

              images = obj.poses.flat_map do |pose|
                copies = obj.recolors.map { |entry| remapped_image(Remapped.new(pose: pose, colors: colors_of_entry(entry))) }
                [@cache.image(picture_named(pose)), *copies]
              end
              @remap_reserved[obj] = @art.drawn_color_words(images).length
              @art.reserve_sprite_colors(images, taker: "the sprite :#{obj.declared || obj.name}")
            rescue Art::TooManyColors
              @copies_overflowed ||= obj
              raise
            end

            # A pose a sprite follows to a list the game never changes (Object#follows_unchanging) shows the
            # colours it was drawn in, and it is cut in its list's order all the same, as a pose of a sprite
            # told `draw_with` that one list is. A background drawing the list draws it from the palette of
            # the list in that order (#recolored_palette), so the two share one of the four. Cut in the order
            # its pixels use the colours, the pose takes a palette of its own beside the background's.
            def follows_unchanging_list?(name)
              drawn_from = picture_named(name).colors_name or return false
              @objects.values.any? { |obj| obj.poses.include?(name) && obj.follows_unchanging&.include?(drawn_from) }
            end

            # The changing list a picture is always drawn with, or nil. A picture every sprite showing it draws
            # with one list the game changes, for good and from power-on (Object#follows), is drawn in that list
            # whatever the list holds, and its own colours are the list's as declared. So it is cut against the
            # list's palette, and keeps no palette for its own colours: a title's sprite and its picture, both
            # drawn with the list, then take one of the four between them.
            #
            # A sprite whose poses are drawn from several lists (Object#follows_each) follows, for each pose,
            # the list that pose is drawn from. The video chip reads a piece's palette from the piece's own
            # entry in the sprite table, two bits beside its tile, and the cartridge writes that entry from
            # the pose's pieces every frame. So each pose's picture is cut against its own list's palette,
            # and the sprite changes palette as it changes pose with no work of its own: the list's write
            # in the blank is what changes its colours.
            def followed_list_of(name)
              drawn_from = picture_named(name).colors_name
              showing = @objects.values.select { |obj| obj.poses.include?(name) }
              lists = showing.map { |obj| obj.follows || obj.list_followed_by_pose(drawn_from) }.uniq
              return lists.first if lists.length == 1

              refuse_followed_by_some!(name, drawn_from) if showing.any? { |obj| obj.list_followed_by_pose(drawn_from) }
            end

            # One picture, shown by a sprite that follows its list and by a sprite that does not: the two
            # would need the picture's pieces to name two palettes.
            def refuse_followed_by_some!(name, list)
              raise NotMadeYet.new("The picture :#{name} is drawn from the list of colors :#{list}. One sprite that shows " \
                                   "it follows that list, and another sprite does not. The Genesis build does not make " \
                                   "that yet. To fix this, tell each sprite that shows :#{name} to follow :#{list}, like " \
                                   "`draw_with({ #{list}: :#{list} })`.", part: "the picture")
            end

            # The colours of the picture's own list, see-through left out.
            def own_colors(image) = image.colors.drop(1).map { |color| color & 0x7FFF }

            # The palette of each list +obj+ is drawn with, in the order the sprite is told them (`recolor` counts
            # from 0 through them), kept for the table the runtime reads. Worked out once for each sprite: a
            # sprite drawing with a list only its scene keeps has them worked out in that scene's copy of the
            # palettes (#allot_shared_colors).
            def recolor_palettes(obj)
              return if obj.recolors.empty? || @recolor_lines&.key?(obj) || remapped?(obj)

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

            # Reference#exec_color_list_holds: the list holds the set the game names, written over its palette in
            # the blank. A list nothing is drawn with has no palette, and nothing to show.
            def emit_color_list_holds(node)
              if backdrop_copied? && backdrop_list.name == node.name
                runtime_call("rt_backdrop_hold", [LabelAddress.new(BACKDROP_COLORS), node.which])
              end
              emit_held_list_write([:sprites, node.name], node.which)
            end

            # The list kept under +key+ (Art#reserve_held_palette) holds the set +which+ names: written over its
            # palette, where it has one. A list only some scenes keep (Art#reserve_scene_held_palette) has the set
            # noted, and is written only while one of them is up, since another scene's own pictures may be in
            # its palette; one of them taking over writes the set noted (#emit_scene_held_lists).
            #
            # A list that shares its palette with other lists (Art#share_held_palette) is written to its own
            # places alone (Runtime::Tint's rt_colors_hold_places), the first and how many.
            def emit_held_list_write(key, which)
              places = @art.held_places_of(key) or return
              palette = places.palette
              table = LabelAddress.new(held_colors_table(key))
              if places.shared
                first = (palette * Art::PLACES) + places.offset
                return runtime_call("rt_colors_hold_places", [table, which, Build.int(first), Build.int(places.count - 1)])
              end

              scenes = @art.scenes_holding(key)
              return runtime_call("rt_colors_hold", [table, which, Build.int(palette)]) unless scenes

              noted = @held_sets.fetch(key)
              value(which)
              store(noted)
              not_up = fresh("held_list_not_up")
              jump_unless(scenes.map { |scene| Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(scene))) }
                                .reduce { |either, other| Build.binop(:or, either, other) }, not_up)
              runtime_call("rt_colors_hold", [table, Build.var_ref(noted), Build.int(palette)])
              @asm.label(not_up)
            end

            # A scene taking over that keeps the palette of a list the game changes (Art#reserve_scene_held_palette):
            # the scene's own colours (#emit_scene_colors) wrote the colours the list starts with over it, so the
            # set the game last told the list to hold, noted as it was told, is written again. The note of the set
            # each palette holds (Runtime::Tint's SETS) is cleared first: another scene's own colours have been
            # there since, and the write would take the same set as written already.
            def emit_scene_held_lists(scene)
              (@held_sets || {}).each do |key, noted|
                next unless @art.scenes_holding(key).include?(scene)

                palette = @art.held_palette_of(key)
                @asm.clr(:l, runtime_at(Runtime::Tint::SETS, palette * Art::PLACES * 4))
                runtime_call("rt_colors_hold", [LabelAddress.new(held_colors_table(key)), Build.var_ref(noted), Build.int(palette)])
              end
            end

            # For each list only some scenes keep, a number of the game's own noting the set it was last told to
            # hold: -1 at power-on, which names no set, so the colours it was declared with (Runtime::Tint's
            # rt_colors_hold).
            def keep_scene_held_sets
              return @held_sets = {} unless lists_take_turns?

              @held_sets = scene_held_lists.keys.select { |key| @art.scenes_holding(key) }.to_h { |key| [key, keep_local(:held_set, start: -1)] }
            end

            # The table rt_colors_hold reads for the list kept under +key+.
            def held_colors_table(key)
              if key.first == :sprites
                list = color_list_named(key[1])
                return held_colors_label([:list, key[1]], list.colors, list.recolors)
              end

              _, id, index = key
              bg = @backgrounds.find { |candidate| candidate.object_id == id }
              held_colors_label(key, bg.palettes.fetch(index), bg.recolors.map { |step| step.fetch(index) })
            end

            # A backdrop that follows a list (IR::Nodes::ColorList#backdrop_place). The video chip's register 7
            # sets which colour of its memory shows wherever nothing is drawn, any of the sixty-four, so where
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

            # Where in the colour memory the backdrop is pointed: a place of the list's own palette, or nil. A
            # list only some scenes keep has its palette given to the other scenes' own pictures while they are
            # up, so the backdrop is copied.
            def backdrop_pointed_at
              list = backdrop_list
              return nil unless tiled? && list && list.backdrop_place.positive?
              return nil if @art.scenes_holding([:sprites, list.name])

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

                emit_held_list_write([:background, bg.object_id, index], node.which)
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

            # How many tiles the game's pictures put in video memory (Genesis::VideoTiles), each scene by
            # the name the game gave it; nil for a game that draws from no tiles.
            public def video_tiles
              return nil unless places_sprites?

              by_scene = @art.tile_count_by_scene.transform_keys { |scene| Modes.strip_scene_prefix(scene) }
              VideoTiles.new(room: @art.most_tiles, every_screen: @art.shared_tile_count, by_scene: by_scene)
            end

            # The picture each picture of the art is, by number, as SpriteNames numbers it.
            def sprite_picture_names = @art.sprite_pictures.map { |_, picture| @sprite_names.picture_number(picture.name) }

            # The art, and each sprite's table of pictures, as sections for the Linker.
            def art_sections
              return [] unless places_sprites?

              @art.refuse_too_many_tiles!
              data = M68000.new("art", holds: ART)
              data.label("art colors")
              data.data_words(@art.color_memory)
              data.label("art tile bytes")
              data.data_longs(@art.tile_data.bytesize)
              @art.sprite_pictures.each_value do |picture|
                data.label(pieces_label(picture.number))
                data.data_words(Runtime::Tiles.picture_words(picture.number, picture.pieces, sprite_tiles_from))
              end
              write_held_colors(data)
              write_backdrop_colors(data)
              write_scene_colors(data)
              write_colors15(data) if (self.class.changing_colors?(@program) || @scene_colors) && !painted? # a painted screen's is Paint#paint_sections'
              data.label("art grids")
              @art.grids.each do |grid|
                data.data_longs(grid_label(grid.number))
                data.data_words(grid.columns, grid.rows)
              end
              @art.grids.each do |grid|
                data.label(grid_label(grid.number))
                data.data_words(grid.words)
              end
              @pose_tables.each do |poses, label|
                data.label(label)
                data.data_longs(poses.length)
                data.data_longs(poses.map { |pose| pieces_label(@art.sprite_pictures.fetch(pose).number) })
              end
              write_front_poses(data)
              (@recolor_tables || []).each do |lines|
                data.label(recolor_table_label(lines))
                data.data_words(lines.length, *lines.map { |line| line << Art::PALETTE_SHIFT })
              end
              (@remapped_tables || {}).each do |tables, label|
                data.label(label)
                data.data_longs(tables)
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
            def front_pieces_label(number) = "art pieces in front #{number}"

            # The pose tables of the sprites drawn in front (#pose_table), and their pictures' pieces
            # with the priority bit set, once for each picture whichever sprites show it.
            private def write_front_poses(data)
              @front_pose_tables.each do |poses, label|
                data.label(label)
                data.data_longs(poses.length)
                data.data_longs(poses.map { |pose| front_pieces_label(@art.sprite_pictures.fetch(pose).number) })
              end
              @front_pose_tables.keys.flatten(1).uniq.each do |pose|
                picture = @art.sprite_pictures.fetch(pose)
                data.label(front_pieces_label(picture.number))
                data.data_words(Runtime::Tiles.picture_words(picture.number, picture.pieces, sprite_tiles_from, in_front: true))
              end
            end
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
                cells = map.map { |row| Array(row).map { |tile| placed_cell_of(bg, tile) } }
                @art.grid(cells, columns, rows)
              end
            end

            # The cell of +bg+'s map showing tile +tile+ (#cell_of), with its priority set where the tile is
            # one of the background's in front of the sprites (Nodes::Background#in_front), as Art.cell_word
            # reads it.
            def placed_cell_of(bg, tile)
              cell = cell_of(bg, tile)
              cell && bg.in_front&.include?(tile) ? [*cell.take(2), true] : cell
            end

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none. Made once
            # for a tile: a map names the same few tiles hundreds of times, and making one reads its 64 pixels.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              run = run_painting(bg.tiles.fetch(tile))
              return @cells_made[[bg.object_id, tile]] ||= run_cell_of(bg, bg.tiles.fetch(tile), run) if run

              @cells_made[[bg.object_id, tile]] ||= begin
                image = @cache.image(picture_named(bg.tiles.fetch(tile)))
                @art.with_tiles_of(tiles_scene_of(bg)) do
                  @art.with_colors_of(colors_scene_of(bg)) do
                    if bg.recolors.empty? && bg.list_followed_by(image.list_drawn_from).nil?
                      @art.background_cell(image, of: bg.name)
                    else
                      palette = recolored_palette(bg, image)
                      @art.background_cell(image, of: bg.name, palette: palette, offset: recolored_offset(bg, image))
                    end
                  end
                end
              end
            end

            # The palette a tile of a background the game draws with other colours is drawn from: one for each list
            # its tiles were drawn from, written over with the colours of the list the game's number names for it
            # (Reference#background_swap). The tile is made of the places of its own list.
            #
            # A background that follows a list the game changes (`recolor`) draws the tiles drawn from that list
            # from the list's palette, the one its sprites are drawn from; a cell's palette is its own, so tiles of
            # its other lists beside them keep palettes of their own at no cost. A Genesis keeps one table of colours for its backgrounds and its
            # sprites together, four palettes of sixteen, so a title whose picture and sprites step through any
            # number of sets of colours costs one palette, written over in the blank, and leaves three for the rest.
            #
            # A background that follows several such lists (Background#follows_each) is the same thing for each of
            # them: its tiles of each list are drawn from that list's palette, and each list's own write changes
            # them. So a screen whose palettes all walk to black fades whole, as a Genesis game's does, and the
            # background has no table of sets and no write of its own.
            #
            # A list that holds the same colours whatever the game sets needs no writing over: a background told
            # `draw_with :machine` and drawn in :machine's own colours shows those colours at every step. So its
            # palette is the list's in the list's order (Art#ordered_palette), which a sprite drawn with the
            # same list shares, rather than one kept to itself. Only place 0 may differ between the sets, since
            # it is see-through and no palette keeps it.
            def recolored_palette(bg, image)
              palette = list_palette_of(bg, image)
              palette.key ? @art.reserve_held_palette(palette.key, palette.colors, name: palette.name) : @art.ordered_palette(palette.colors)
            end

            # The place before the first of the list that palette's tile is drawn from (#recolored_palette): 0,
            # but for a background's list that shares a palette with others (Art#share_held_palette).
            def recolored_offset(bg, image)
              key = list_palette_of(bg, image).key
              key ? @art.held_offset_of(key) : 0
            end

            # The palette a tile of +bg+ drawn with other colours is drawn from (#recolored_palette), before it is
            # allotted: +key+ is whose list keeps it to itself (Art#reserve_held_palette), or nil for a list in its
            # own order (Art#ordered_palette), and +colors+ the colours it starts with (15-bit, see-through left out).
            # +name+ is what a refusal calls a background's own list (Art#held_name), nil for a list the game named.
            ListPalette = Data.define(:key, :colors, :name)

            def list_palette_of(bg, image)
              list = bg.recolored_list_of(image.list_drawn_from) or
                raise LoweringError, "a tile of the background #{bg.name.inspect} is drawn from a list of colours it was not given"
              index = bg.drawn_lists.index(list)
              colors = bg.palettes.fetch(index).drop(1).map { |color| color & 0x7FFF }
              followed = bg.follows_several? ? bg.follows_each.fetch(index) : (bg.follows if index == bg.followed_list_index)
              return ListPalette.new(key: nil, colors: colors, name: nil) if !followed && unchanging_colors?(bg, index, colors)
              return ListPalette.new(key: [:sprites, followed], colors: colors, name: nil) if followed

              ListPalette.new(key: [:background, bg.object_id, index], colors: colors,
                              name: "a list of colours of the background :#{bg.name}")
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

              # Put up again, it keeps the cells its plane holds (SceneryWrites#emit_put_up_keeping_cells).
              emit_put_up_keeping_cells(node, layer_of(node)) { |kept| emit_put_up(node, kept ? nil : 0, reset_view: 1) }
            end

            # +which+ is the map whose cells go onto the plane, or nil to keep the cells the plane holds: then
            # nothing is copied, and the view goes back to the corner as rt_background_put_up puts it there.
            #
            # The plane shows the background's bend from here on, or none (Bends#emit_bend_shown).
            def emit_put_up(bg, which, reset_view:)
              emit_bend_shown(layer_of(bg), bg)
              if which
                runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, which).number), Build.int(reset_view)])
              else
                runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), Build.int(0), Build.int(0)])
              end
              note = corner_note(layer_of(bg)) if reset_view.nonzero?
              statement(Build.set(note, 1)) if note
            end

            # Reference#exec_scroll_background. A put-up holds its plane at the corner through its pass
            # (SceneryWrites#keep_corner_notes).
            def emit_scroll_background(node)
              for_background(node) do |bg|
                emit_unless_put_up(node, corner_note(layer_of(bg))) do
                  runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
                end
              end
            end

            # A block of cells is noted as one command for the blank (Runtime::Tiles#emit_block_noted),
            # as a console's own game queues a box for its interrupt to lay: the block's place and size
            # and the one cell's word, or where the map's own cells are in the cartridge. The blank
            # writes its cells a row at a time, the chip moving on by itself from cell to cell, so a
            # block of two hundred cells costs the pass what one cell does. Its children, the same
            # cells written one by one, are what the interpreter plays (Reference#exec_set_tile_block);
            # the checked run holds this to them.
            #
            # This is the one lowering that does not play the children, and the measurement is why: a
            # speech box of 189 cells written one by one took the pass nearly a whole frame, each
            # cell a test of its place and a call to note it, and written as five blocks it takes a
            # small part of one, the blank writing a word a cell
            # (test/lowering/genesis/vblank/ir/backends/genesis/test_genesis_cell_blocks.rb).
            def emit_set_tile_block(node) = for_background(node) { |bg| emit_set_tile_block_of(bg, node) }

            def emit_set_tile_block_of(bg, node)
              columns, rows = TileMap.size_of(bg.every_map.first)
              base = (Runtime::Tiles.cell_command >> 16) + (layer_of(bg).odd? ? Runtime::Tiles::PLANE_B_AT - Runtime::Tiles::PLANE_A_AT : 0)
              word, skipped = emit_block_cell_word(bg, node)
              return unless word

              description =
                if node.restore
                  grid = grid_of(bg, 0)
                  [columns, rows, base, grid.columns * 2, grid_label(grid.number)]
                else
                  [columns, rows, base, 0, 0]
                end
              label = @cell_blocks[description] ||= "cell block #{@cell_blocks.length + 1}"
              runtime_call("rt_note_block", [node.col, node.row, node.across, node.down, word]) do
                @asm.lea(@asm.abs_l(label), @asm.a(0))
              end
              @asm.label(skipped) if skipped
            end

            # What D4 is handed for +node+'s block on +bg+: the one cell's word, a number or a number of
            # the lowering's own it was read into, and the label to jump to where the picked number
            # stands for no tile; nil where no cell is written at all. A block put back takes nought.
            def emit_block_cell_word(bg, node)
              return [Build.int(0), nil] if node.restore
              unless node.picked?
                return nil if node.tile && node.tile >= bg.tiles.length

                return [Build.int(cell_word_of(bg, node.tile)), nil]
              end

              words = PickedTile.words(node) { |tile| cell_word_of(bg, tile) if tile < bg.tiles.length } or return nil

              table = @cell_tables[words] ||= "cells #{@cell_tables.length + 1}"
              skipped = fresh("block_skipped")
              word = keep_local(:block_cell)
              value(node.picked_by)
              @asm.sub(:l, @asm.imm(node.picks_from), @asm.d(0)) unless node.picks_from.zero?
              @asm.cmp(:l, @asm.imm(words.length), @asm.d(0))
              @asm.branch(:cc, skipped)
              @asm.add(:l, @asm.d(0), @asm.d(0)) # two bytes a word
              @asm.lea(@asm.abs_l(table), @asm.a(0))
              @asm.moveq(0, @asm.d(1))
              @asm.move(:w, @asm.idx(0, 0, 0), @asm.d(1))
              if words.include?(PickedTile::NO_CELL)
                @asm.cmp(:w, @asm.imm(PickedTile::NO_CELL), @asm.d(1))
                @asm.branch(:eq, skipped)
              end
              @asm.move(:l, @asm.d(1), var(word))
              [Build.var_ref(word), skipped]
            end

            # Whether the game changes a block of cells in one step, whose runtime the build then carries.
            public def writes_cell_blocks? = @program.walk.any? { |node| node.kind == :set_tile_block }

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map. A tile picked by a number known now is that tile
            # (IR::PickedTile.written).
            def emit_set_tile(node)
              if node.picked? && (number = folded(node.picked_by))
                written = PickedTile.written(node, number)
                return written && emit_set_tile(written)
              end
              for_background(node) { |bg| emit_set_tile_of(bg, node) }
            end

            def emit_set_tile_of(bg, node)
              return emit_set_picked_tile_of(bg, node) if node.picked?
              return if node.tile && node.tile >= bg.tiles.length

              word = cell_word_of(bg, node.tile)
              emit_cell_noted(bg, node) { |_outside| @asm.move(:w, @asm.imm(word), @asm.d(3)) }
            end

            # The cell at +node+'s column and row of +bg+ noted to change in the blank (Runtime::Tiles's
            # rt_note_cell), to the word the block leaves in D3; the block is handed the label to jump
            # to when the cell is to be left alone, and may use D0 and A0.
            #
            # A retail game stores the word in its copy of the plane in four or five instructions,
            # because it knows where the cell is. So what is known here is worked out here: a column
            # or a row written in the program is tested now and takes no instruction, one that is a
            # variable is tested where it is kept, and the first word of the command that points the
            # chip at the cell (Runtime::Tiles.cell_command) is put together from them in D1, with
            # the plane and everything else that is a number folded into one sum.
            def emit_cell_noted(bg, node)
              columns, rows = TileMap.size_of(bg.every_map.first)
              column = cell_place_operand(node.col, :column)
              row = cell_place_operand(node.row, :row)
              return if place_off_map?(column, columns) || place_off_map?(row, rows)

              outside = fresh("cell_outside")
              emit_jump_unless_below(column, columns, outside) unless column.is_a?(Integer)
              emit_jump_unless_below(row, rows, outside) unless row.is_a?(Integer)
              yield outside
              emit_cell_command_word(bg, column, row)
              call_routine("rt_note_cell")
              @asm.label(outside)
            end

            # Where a column or row of a cell can be read with nothing worked out: the number itself
            # for one written in the program, or the variable it is. Any other is worked out now into
            # a number of the lowering's own, one for every cell the game changes, each used only
            # until its cell is noted.
            def cell_place_operand(node, what)
              known = folded(node)
              return known if known

              name = variable_named(node)
              return name if name

              local = (@cell_place_locals ||= {})[what] ||= keep_local(what)
              value(node)
              store(local)
              local
            end

            def place_off_map?(place, limit) = place.is_a?(Integer) && !place.between?(0, limit - 1)

            # D1 the first word of the command for the cell at +column+ and +row+ of +bg+'s plane,
            # each a number or the variable holding one, both inside the map. A cell is two bytes and
            # a row of the plane its cells across, so the place is the row shifted, plus the column,
            # doubled; plane B's map is 8K past plane A's.
            def emit_cell_command_word(bg, column, row)
              shift = plane_size.first == 64 ? 6 : 5
              fixed = (Runtime::Tiles.cell_command >> 16) + (layer_of(bg).odd? ? Runtime::Tiles::PLANE_B_AT - Runtime::Tiles::PLANE_A_AT : 0)
              fixed += row << (shift + 1) if row.is_a?(Integer)
              fixed += column << 1 if column.is_a?(Integer)
              d1 = @asm.d(1)
              return @asm.move(:w, @asm.imm(fixed), d1) if row.is_a?(Integer) && column.is_a?(Integer)

              if row.is_a?(Integer)
                @asm.move(:w, low_word_of(column), d1)
              else
                @asm.move(:w, low_word_of(row), d1)
                @asm.lsl(:w, shift, d1)
                @asm.add(:w, low_word_of(column), d1) unless column.is_a?(Integer)
              end
              @asm.add(:w, d1, d1)
              @asm.add(:w, @asm.imm(fixed), d1)
            end

            # The low half of the variable +name+, which is the whole of a number tested to be small.
            def low_word_of(name) = at(place_of(name), 2)

            # The word a cell of +bg+ showing its tile +tile+ holds in the plane's map: the tile's number
            # in video memory, its palette and its priority, and nought for no tile.
            def cell_word_of(bg, tile) = Art.cell_word(placed_cell_of(bg, tile))

            # A tile picked as the game runs (Nodes::SetTile#picked_by) is a word read from a table, as
            # a console's own game writes its text: the number, less the one the list starts at, is a
            # place in a table of the words those tiles' cells hold, kept in the cartridge. One
            # comparison holds the number to the table, since read with no sign a number below the
            # first is far past the last. A number that stands for no tile reads PickedTile::NO_CELL, and the
            # cell is left alone, as is a tile only another scene's background of the name has.
            def emit_set_picked_tile_of(bg, node)
              words = PickedTile.words(node) { |tile| cell_word_of(bg, tile) if tile < bg.tiles.length } or return

              table = @cell_tables[words] ||= "cells #{@cell_tables.length + 1}"
              emit_cell_noted(bg, node) do |outside|
                value(node.picked_by)
                @asm.sub(:l, @asm.imm(node.picks_from), @asm.d(0)) unless node.picks_from.zero?
                @asm.cmp(:l, @asm.imm(words.length), @asm.d(0))
                @asm.branch(:cc, outside)
                @asm.add(:l, @asm.d(0), @asm.d(0)) # two bytes a word
                @asm.lea(@asm.abs_l(table), @asm.a(0))
                @asm.move(:w, @asm.idx(0, 0, 0), @asm.d(3))
                if words.include?(PickedTile::NO_CELL)
                  @asm.cmp(:w, @asm.imm(PickedTile::NO_CELL), @asm.d(3))
                  @asm.branch(:eq, outside)
                end
              end
            end

            # A jump to +outside+ unless the number kept in +local+ is from nought up to +limit+, which
            # is one comparison: read as a number with no sign, one below nought is far past any limit.
            def emit_jump_unless_below(local, limit, outside)
              @asm.cmp(:l, @asm.imm(limit), operand_of(Build.var_ref(local)))
              @asm.branch(:cc, outside)
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
              emit_scene_colors(scene)
              emit_scene_held_lists(scene)
              emit_scene_backdrop(scene)
              return if @scene_layers.zero?

              arrival = @handover.arrival(scene)
              arrival.map_choices.each { |var| store_number(var, 0) }
              arrival.scenery.each { |bg| emit_put_up(bg, 0, reset_view: 1) }
              # Tiles its scenery paints from a list show the list as it is now, changed or not, written
              # in the blank after any tiles of its own (Reference#copy_run_tiles).
              arrival.painted_tiles.each { |run| emit_run_copy(run) }
              unused = (0...@scene_layers).to_a - arrival.scenery.map { |bg| layer_of(bg) }
              return if unused.empty?

              first = fresh("scene_first")
              jump_unless(Build.binop(:!=, Build.var_ref(before), Build.int(-1)), first)
              unused.each do |plane|
                runtime_call("rt_background_put_up", [Build.int(plane), Build.int(empty_grid.number), Build.int(1)])
                emit_bend_shown(plane, nil)
              end
              @asm.label(first)
            end

            # A scene taking over, in a game of +scene_tiles+: its own tiles go into video memory over the last
            # scene's, in the blank at the end of this pass (Runtime::Tiles' rt_scene_tiles). The pass is its
            # own with `loads_first:`, and shared with the scene's first pass of game without.
            def emit_scene_tiles(scene)
              return unless @scene_tiles

              runtime_call("rt_scene_tiles", [LabelAddress.new(scene_tiles_table_label(scene))])
            end

            # A scene taking over, in a game of +scene_colors+: the palettes its own pictures are drawn from are
            # written into the game's colours (Runtime::Tint's rt_scene_colors), and the colour memory is worked
            # out from them as this pass ends, through the fade or tint in force, as any change of colour is.
            # So a scene that comes in under a screen faded to black shows black, and its own colours as the
            # fade lifts. A scene with no colours of its own writes nothing.
            def emit_scene_colors(scene)
              return unless @scene_colors

              runtime_call("rt_scene_colors", [LabelAddress.new(scene_colors_label(scene))])
            end

            # A scene taking over, in a game whose scenes differ in their backdrop: colour 0 changed to its
            # own, or the game's where it says none. It goes out with the scene's colours, through whatever
            # fade is in force (Runtime::Tint's rt_scene_backdrop).
            def emit_scene_backdrop(scene)
              @scene_backdrops = Picture.scene_backdrops?(@program, @handover) if @scene_backdrops.nil?
              return unless @scene_backdrops && (backdrop = @handover.arrival(scene).backdrop)

              runtime_call("rt_scene_backdrop", [Build.int(backdrop & 0x7FFF)])
            end

            def scene_colors_label(scene) = "art scene colors #{scene}"

            # For each scene, the table rt_scene_colors reads (Runtime::Tint): how many palettes it writes, then
            # for each its number, how many of its places hold a colour, and its fifteen colours (Art#scene_palette_writes).
            def write_scene_colors(data)
              return unless @scene_colors

              @scenes.each_key do |scene|
                writes = @art.scene_palette_writes(scene)
                data.label(scene_colors_label(scene))
                data.data_words(writes.length)
                writes.each { |write| data.data_words(write.palette, write.used, *write.colors) }
              end
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
              IR::Stacking.items_in_draw_order(node).each do |item|
                next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                emit_sprite_placing(object_named(item))
              end
              call_routine("rt_sprites_end")
              @asm.label(done)
            end

            def object_named(name) = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }

            # One sprite placed, if it is showing: its numbers into the registers the runtime reads
            # them from (Runtime::Tiles#emit_sprites) and a call. +returns+ for a placing that is
            # itself called (#emit_ordered_run): it goes to the runtime with a jump, whose return is
            # then the placing's own.
            #
            # The walk's registers are the runtime's from rt_sprites_begin to rt_sprites_end, so
            # nothing written between two sprites may change them. A sprite's numbers are nearly
            # always variables, or sums of them the lowering writes in place with D0, D1, D2 and A0
            # alone (Lowering#value_keeps_counters?). One that calls the runtime could change
            # anything, so the walk's registers go on the stack while it is worked out
            # (#emit_sprite_numbers_worked_out).
            #
            # +shown_known+ for a sprite already found showing on this pass (#emit_ordered_run): it is
            # placed without being asked.
            def emit_sprite_placing(obj, returns: false, shown_known: false)
              skip = fresh("sprite_off")
              numbers = [obj.pose, obj.x, obj.y]
              numbers << obj.recolor unless obj.recolors.empty?
              shown = shown_known ? ShownWhen.new(tests: [], flag: nil) : shown_when(obj.active)
              if shown && numbers.all? { |number| value_keeps_counters?(number) }
                emit_jump_unless_shown(shown, skip, near: shown.tests.empty? && numbers.all? { |number| operand_of(number) })
                emit_sprite_numbers_in_place(numbers)
              else
                emit_sprite_numbers_worked_out(shown_known ? Build.int(1) : obj.active, numbers, skip)
              end
              emit_pose_wanted(obj)
              @asm.lea(@asm.abs_l(pose_table(obj)), @asm.a(0))
              emit_operand_load(@asm.imm(@sprite_names.name_number(obj.declared)), 0)
              routine = "rt_sprite_place"
              if remapped?(obj)
                emit_remapped_pose_table(obj)
              elsif !obj.recolors.empty?
                @asm.move(:l, @asm.imm(recolor_table_label(@recolor_lines.fetch(obj))), @asm.d(6))
                routine = "rt_sprite_place_recolored"
              end
              returns ? @asm.jmp(@asm.abs_l(routine)) : call_routine(routine)
              @asm.label(skip)
              @asm.rts if returns
            end

            # +active+ as tests (Backends::ShownWhen), each written in place, or nil. A multiply of two
            # long words, which the product would otherwise be, has no instruction on the 68000: a
            # call, and three of its word multiplies.
            def shown_when(active)
              shown = ShownWhen.of(active) { |part| folded(part) }
              shown if shown && ShownWhen.factors_of(active).all? { |factor| value_keeps_counters?(factor) }
            end

            # On to +skip+, the end of the sprite's placing, unless it shows (ShownWhen). A sprite that
            # shows goes on past every branch. +near+ where +skip+ is only a few instructions on, so
            # the branch after a flag that is a variable can be a near one (M68000#branch_near).
            def emit_jump_unless_shown(shown, skip, near:)
              place = shown.flag && operand_of(shown.flag)
              if near && place&.mode == :disp
                @asm.cmp(:l, @asm.imm(1), place)
                @asm.branch_near(:ne, skip)
              elsif shown.flag
                jump_unless(Build.binop(:==, shown.flag, Build.int(1)), skip)
              end
              shown.tests.each { |test| jump_unless(test, skip) }
            end

            # The registers a sprite's numbers go in, in the order #emit_sprite_placing lists them: which
            # picture, across, down, and for a sprite drawn in a list of colours, which list. And where
            # each waits while the others are worked out, since working one out uses D0, D1 and D2.
            SPRITE_NUMBER_REGISTERS = [1, 2, 3, 5].freeze
            SPRITE_NUMBER_WAITS_IN = [7, 6, 3, 5].freeze

            # +numbers+, each written in place (Lowering#value_keeps_counters?), into their registers:
            # the ones that need working out first, then the numbers and variables read where they are.
            def emit_sprite_numbers_in_place(numbers)
              worked_out = numbers.each_index.reject { |i| operand_of(numbers[i]) }
              worked_out.each do |i|
                value(numbers[i])
                @asm.move(:l, @asm.d(0), @asm.d(SPRITE_NUMBER_WAITS_IN.fetch(i)))
              end
              numbers.each_with_index do |number, i|
                next if worked_out.include?(i)

                emit_operand_load(operand_of(number), SPRITE_NUMBER_REGISTERS.fetch(i))
              end
              worked_out.each do |i|
                waits_in = SPRITE_NUMBER_WAITS_IN.fetch(i)
                register = SPRITE_NUMBER_REGISTERS.fetch(i)
                @asm.move(:l, @asm.d(waits_in), @asm.d(register)) unless waits_in == register
              end
            end

            # The registers the walk keeps (Runtime::Tiles#emit_sprites).
            WALK_REGISTERS = %i[d4 a2 a3].freeze

            # +active+ worked out, then +numbers+ if it is 1, each into its register, with the walk's
            # registers kept on the stack meanwhile; or on to +skip+ for a sprite that is not showing.
            def emit_sprite_numbers_worked_out(active, numbers, skip)
              showing = fresh("sprite_showing")
              @asm.movem_push(:l, *WALK_REGISTERS)
              value(active)
              @asm.subq(:l, 1, @asm.d(0))
              @asm.branch(:eq, showing)
              @asm.movem_pop(:l, *WALK_REGISTERS)
              @asm.bra(skip)
              @asm.label(showing)
              numbers.each { |number| push_value(number) }
              numbers.each_index.reverse_each do |i|
                @asm.move(:l, @asm.post(M68000::SP), @asm.d(SPRITE_NUMBER_REGISTERS.fetch(i)))
              end
              @asm.movem_pop(:l, *WALK_REGISTERS)
            end

            def recolor_table_label(lines) = "art recolors #{@recolor_tables.index(lines)}"

            # A0 from the pose table of the copies (#remapped?) in the list D5 names, read from a table of
            # the sprite's pose tables, a long for each list; a D5 naming none, below nought or past the
            # last, keeps A0 at the sprite's own (#emit_sprite_placing). Six instructions, once a sprite,
            # and nothing more for each piece, where a sprite drawn from a palette for each list changes
            # every piece's palette as it is placed (Runtime::Tiles, rt_sprite_place_recolored).
            def emit_remapped_pose_table(obj)
              own = fresh("sprite_own_colors")
              tables = obj.recolors.map { |entry| pose_table(obj, colors_of_entry(entry)) }
              @remapped_tables ||= {}
              label = @remapped_tables[tables] ||= "art remapped poses #{@remapped_tables.length}"
              tables.length < 128 ? @asm.moveq(tables.length, @asm.d(6)) : @asm.move(:l, @asm.imm(tables.length), @asm.d(6))
              @asm.cmp(:l, @asm.d(6), @asm.d(5))
              @asm.branch_near(:cc, own) # read with no sign, a list below nought is past the last
              @asm.lsl(:w, 2, @asm.d(5))
              @asm.lea(@asm.abs_l(label), @asm.a(1))
              @asm.movea(:l, @asm.idx(1, 0, 5, :w), @asm.a(0))
              @asm.label(own)
            end

            # A run the game puts in order as it runs (Reference#names_in_draw_order): its list holds the
            # run's sprites back to front, each by its place in the run, so each entry in turn places
            # the sprite it names. Each sprite's placing is written out once, here, ending in a return,
            # so the entries share it.
            #
            # The entry picks its placing from a table of their addresses, a long each, kept beside
            # the code: four instructions an entry, whatever the run's length. Asking each entry "is
            # it the first? the second?..." in turn would cost every entry a test for each sprite
            # before it, so the whole run a test for every pair of its sprites. A sorted order keeps
            # its items four times over in a table of its own (Lowering#emit_keyed_sort), so its entry
            # is one read. The placing is here rather than a routine of its own, which took a long
            # JSR and an RTS more for every ordered sprite.
            #
            # The framework's own list (Build::DrawOrder#permutation) holds every place of the run in
            # its slots, so each entry is read straight from its slot with nothing tested. Any other
            # list — one written by hand, or one something takes items from the front of, whose slots
            # move round — is walked as the interpreter reads it (DrawOrderWalk), through the same table.
            #
            # A sorted run keeps its entries not showing at its front (ShownSort), so the walk starts past
            # them, and every entry it reaches was found showing by the sort on this pass: a place the
            # sort asked is placed without being asked again.
            def emit_ordered_run(run)
              table = fresh("ordered_placings")
              past = fresh("past_ordered_placings")
              placings = run.objects.map { fresh("ordered_placing") }
              slots = order_read_by_slots?(run, @lists_dropped_from_front)
              shown = (@shown_sorts&.fetch(run.order, nil) if slots)
              @asm.bra(past)
              @asm.label(table)
              @asm.data_longs(placings)
              run.objects.each_with_index do |name, place|
                @asm.label(placings[place])
                emit_sprite_placing(object_named(name), returns: true, shown_known: shown&.asked&.fetch(place))
              end
              @asm.label(past)
              return emit_ordered_run_walked(run, table) unless slots

              keyed = @keyed_sorts&.fetch(run.order, nil)
              steps = run.objects.each_index.map { fresh("ordered_step") } + [fresh("ordered_steps_done")]
              emit_steps_past_hidden(shown, steps) if shown
              run.objects.each_index do |k|
                @asm.label(steps[k])
                if keyed
                  @asm.move(:w, at(keyed.entries, k * 2), @asm.d(0))
                else
                  emit_order_entry_read(run.order, k)
                  @asm.lsl(:l, 2, @asm.d(0))
                end
                emit_ordered_placing_called(table, keyed ? :w : :l)
              end
              @asm.label(steps.last)
            end

            # D0 = entry +k+ of the order list +order+, whose first item is in its first slot, read from
            # its slot's address, where reading it through the runtime would take a call, and the
            # list's place found and the index scaled there.
            def emit_order_entry_read(order, k)
              slot = slot_place(order)
              bytes = slot.width
              @asm.moveq(0, @asm.d(0)) unless bytes == 4
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), @asm.abs_l(area_place(slot), Runtime::Lists::HEADER + slot.at(k)),
                        @asm.d(0))
            end

            # The placing D0 picks from +table+, by a +size+ (:w or :l) index four times the place, called.
            def emit_ordered_placing_called(table, size)
              @asm.lea(@asm.pc_rel(table), @asm.a(0))
              @asm.movea(:l, @asm.idx(0, 0, 0, size), @asm.a(0))
              @asm.jsr(@asm.ind(0))
            end

            # A run whose list is walked as the interpreter reads it (DrawOrderWalk).
            def emit_ordered_run_walked(run, table)
              emit_draw_order_walk(run) do |place|
                @asm.move(:l, var(place), @asm.d(0))
                @asm.lsl(:l, 2, @asm.d(0))
                emit_ordered_placing_called(table, :l)
              end
            end

            # DrawOrderWalk's: a read of the list may call the runtime, which can change anything, so
            # the walk's registers go on the stack meanwhile (#emit_sprite_placing).
            def emit_sprite_walk_read(name, value)
              @asm.movem_push(:l, *WALK_REGISTERS)
              statement(Build.set(name, value))
              @asm.movem_pop(:l, *WALK_REGISTERS)
            end

            # DrawOrderWalk's: the place the variable +name+ holds and the run's +count+, the fault's two
            # numbers, and no list, as the interpreter words it (Faults.draw_order_names_none).
            def emit_draw_order_fault(name, count)
              @asm.move(:l, @asm.imm(0), runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_LIST))
              @asm.move(:l, var(name), runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_FIRST))
              @asm.move(:l, @asm.imm(count), runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_SECOND))
              @asm.moveq(Runtime::Frame::DRAW_ORDER_NAMES_NONE, @asm.d(0))
              @asm.jmp(@asm.abs_l("rt_fault"))
            end

            # The table of a sprite's pictures: how many, then where each one's pieces are. It is kept by
            # the pictures it lists, so sprites that face the same poses, in the same order, read one
            # table: a pool's things, or thirty actors that can each show any frame of one sheet.
            #
            # A sprite kept to one pose reads a table of its own, of its pictures drawn from its room
            # (PoseRooms), each kept under the sprite's name and the pose's.
            # A sprite drawn in front (Nodes::Object#in_front) reads its pictures' pieces from copies
            # whose words have the priority bit set (#front_pose_sections), so a sprite that shows one
            # of them beside it, not in front, keeps its own.
            #
            # +colors+ (a list's colours, place 0 first) for the table of the sprite's copies in that list
            # (#remapped?).
            def pose_table(obj, colors = nil)
              pictures = if colors then obj.poses.map { |name| Remapped.new(pose: name, colors: colors) }
                         elsif streamed?(obj) then obj.poses.map { |name| room_key(obj, name) }
                         else obj.poses
                         end
              return @pose_tables[pictures] ||= "poses #{@pose_tables.length}" unless obj.in_front

              @front_pose_tables[pictures] ||= "poses in front #{@front_pose_tables.length}"
            end

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = store_number(sprites_hidden_flag, 1)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
