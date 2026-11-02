# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # THE PICTURE, lowered for a Super Nintendo: the statements that draw, as calls into
          # Runtime::Picture, and the game's pictures made into tiles, palettes and maps (SNES::Art)
          # while the program is built.
          #
          # A TILED SCREEN. Each background the game declares is given one of the console's two
          # layers of sixteen-colour tiles, the one declared last in front (BG1), as the interpreter
          # paints the one declared last over the rest. Each map it can show is made into a grid of
          # 32 or 64 cells each way (IR::TileMap), kept whole in the cartridge and copied onto its
          # layer when it is put up. Each sprite is made of the console's 8×8 sprite pieces, placed
          # in the sprite table every pass the game places its sprites.
          module Picture
            STATEMENTS = Ractor.make_shareable({
                                                 screen: :emit_screen, background: :emit_background,
                                                 scroll_background: :emit_scroll_background,
                                                 set_tile: :emit_set_tile, show_map: :emit_show_map,
                                                 present_objects: :emit_present_objects,
                                                 hide_sprites: :emit_hide_sprites, fade: :emit_fade, tint: :emit_tint,
                                                 place_bar: :emit_place_bar, scroll_rows: :emit_scroll_rows,
                                                 copy_tiles: :emit_copy_tiles, copy_owed_tiles: :emit_copy_owed_tiles,
                                                 background_colors: :emit_background_colors,
                                                 color_list_holds: :emit_color_list_holds,
                                                 see_through: :emit_see_through_amount
                                               })

            # Whether +program+ has a status bar, which the runtime then carries what places
            # (Runtime::Picture's rt_bar_place).
            def self.status_bar?(program) = program.walk.any? { |node| node.kind == :background && node.bar? }

            # Whether +program+ changes colours as it runs, which the runtime then keeps a place for
            # (Runtime::Tint's rt_colors_hold).
            def self.changing_colors?(program) = program.walk.any? { |node| %i[background_colors color_list_holds].include?(node.kind) }

            # Does the game fade to black, which the display's brightness does (Runtime::Tint)?
            def self.fades_to_black?(program) = program.walk.any? { |node| node.kind == :fade && node.toward != :white }

            # Whether +program+ bends a background row by row, which the runtime then keeps the rows
            # and line tables of (Runtime::Picture's rt_bends_prepare).
            def self.bends?(program) = program.walk.any? { |node| node.kind == :scroll_rows }

            # Whether a background a scene puts up is bent, whose rows then go straight while that
            # scene is away (Runtime::Picture::LAYERS_STRAIGHT).
            def self.scene_bends?(program)
              always = IR::SceneHandover.of(program).always_up.scenery.map(&:name)
              program.walk.any? { |node| node.kind == :scroll_rows && !always.include?(node.name) }
            end

            # The runs of tiles +program+ paints from lists (Builder::TileRuns), each once, in the order
            # they were declared: the order the runtime numbers them in.
            def self.tile_runs(program) = program.walk.select { |node| node.kind == :tile_run }.uniq(&:name)

            # The bytes each run's tiles take in the console's form, which the runtime stages a copy in.
            # A run held in the cartridge is never staged, so it has none.
            def self.tile_run_bytes(program)
              tile_runs(program).map do |run|
                next 0 if run.held_in

                (run.picture ? (run.width / 8) * (run.height / 8) : run.tiles.length) * 32
              end
            end

            # THE RUNS WHOSE PICTURES ARE HELD IN THE CARTRIDGE (`tile_pictures`), as each run's number
            # and how many strips of tiles it is copied in. Converting a list's places into the console's
            # form takes the processor a good part of a frame, and these are known while the game is
            # built, so they go into the cartridge in that form and the copying engine reads them from
            # there, in the blank, with nothing for the processor to do. The console reads a run's tiles
            # in a line of video memory, so a run of 8×8 tiles is one strip. A big tile is a strip for
            # its top two quarters and one for its bottom two, sixteen tiles further on.
            def self.held_runs(program)
              tile_runs(program).each_with_index.select { |run, _| run.held_in }.to_h do |run, number|
                [number, run.tile_side == BIG_TILE ? run.tiles.length * 2 : 1]
              end
            end

            # The SNES::Art the game's pictures were made into.
            attr_reader :art

            # The runs of the colour memory a picture can show, which a fade moves (Runtime::Tint). A
            # painted screen's colours are Lowering::Paint's: those it paints in, or every one in a
            # game with sprites, which draw from the colour memory's second half.
            def colors_shown
              return @art.colors_shown unless painted?

              @objects.empty? ? [[0, @painted_art.colors_painted]] : [[0, 256]]
            end

            # Whether any sprite picture is drawn with squares of 16×16 (Art::Piece#big).
            def sprite_squares? = !painted? && @art.sprite_squares?

            # What the build can say about the table of 128 rows. A sprite past the last row is not
            # drawn, with no error from the console, and only here is it known how many rows each
            # picture came to. A pool's sprites and letters of text are left out of the count: how
            # many show at once is decided as the game runs, so this counts what is certain, the
            # sprites a screen declares, each at its largest pose.
            def sprite_table_findings
              return [] if painted?

              screen = IR::SpriteRows.plan(@program) { |node| rows_of_declared_sprite(node) }.busiest
              return [] if screen.nil? || screen.count <= Runtime::Picture::MOST_SPRITES

              [Guardrails::Finding.new(
                check: :snes_sprite_table, severity: :warning, node: :program,
                message: "The sprites of one screen take #{screen.count} rows of the sprite table. A Super " \
                         "Nintendo has #{Runtime::Picture::MOST_SPRITES}, and a sprite past the last row is not " \
                         "drawn. Each piece of a picture takes one row. To fix this, use fewer sprites, or make " \
                         "their pictures of fewer pieces."
              )]
            end

            def rows_of_declared_sprite(node)
              return 0 if node.declared.nil? || Guardrails::SpriteWords.pool?(node)

              @objects.fetch(node.name).poses.map { |pose| @art.sprite_pictures.fetch(pose).pieces.length }.max.to_i
            end

            def prepare_picture
              refuse_backdrops_of_its_own!
              @art = Art.new(backdrop: IR::SceneHandover.of(@program).game_backdrop, sprite_squares: @sprite_squares,
                             screen_colors: @screen_colors, sprite_colors: @sprite_colors, scene_tiles: @sprite_tiles,
                             background_tiles: @scene_background_tiles)
              sizes = @program.walk.select { |node| node.kind == :background }.map(&:tile_w).uniq
              @art.reserve_blank_big_tile if sizes.length > 1
              @pictures = by_kind(:bitmap)
              @objects = by_kind(:object)
              @backgrounds = by_kind(:background)
              @sprite_names = SpriteNames.new(@program)
              @grids = {}
              @pose_tables = {}
              @tile_runs = Picture.tile_runs(@program)
              @run_cells = {} # a run's tile's image name -> [tile, palette]
              @run_places = [] # each run's first tile's word in video RAM
              @held_strips = [] # each strip of the runs held in the cartridge (Picture.held_runs)
            end

            # Each piece of the picture this lowering does not make yet, refused by name: the
            # build makes a tiled screen of 8×8 tiles, at most two backgrounds, and plain sprites,
            # or a painted screen (Lowering::Paint) with nothing drawn from tiles over it.
            def refuse_unmade_picture!
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              others = screens - %i[tiled bitmap]
              refuse_unmade!("a `screen :#{others.first}`") unless others.empty?
              refuse_unmade!("both a painted (bitmap) screen and a tiled one") if screens.include?(:tiled) && painted?
              if painted?
                refuse_unmade!("a background on a painted (bitmap) screen") unless @backgrounds.empty?
                refuse_unmade!("a hardware sprite on a painted (bitmap) screen") unless @objects.empty?
              end
              @program.walk.select { |node| node.kind == :background }.each do |bg|
                unless bg.tile_w == bg.tile_h && [8, BIG_TILE].include?(bg.tile_w)
                  refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}")
                end
                refuse_unmade!("a background drawn from several sets of tiles") if bg.several_sets?
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
              end
            end

            # Every picture a sprite can show, made into sprite pieces in the order SpriteNames numbers
            # them, a canvas's picture among them (#make_run_art), so the number a picture is made
            # with is the one a reader of the drawn sprites turns back into its name.
            #
            # The pictures of a see-through layer's sprites are drawn from the console's last four
            # sprite palettes, and every other picture from the first four (Art#split_sprite_palettes!),
            # so a picture both kinds of sprite show would need to be made twice, which is not made yet.
            def make_sprite_art
              @art.split_sprite_palettes! unless see_through_sprites.empty?
              @sprite_pictures = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              mixed = see_through_sprites.flat_map { |name| @objects.fetch(name).poses }.uniq
              solid = (@objects.values.reject { |obj| see_through_sprites.include?(obj.name) }.flat_map(&:poses) +
                       @tile_runs.filter_map(&:picture)).uniq
              refuse_unmade!("a picture shown both by a see-through sprite and by another") if mixed.intersect?(solid)

              painted = @tile_runs.filter_map(&:picture)
              reserve_shared_sprite_art(mixed, painted)
              @sprite_pictures.each_with_index do |name, number|
                run = @tile_runs.index { |tile_run| tile_run.picture == name }
                if painted.include?(name)
                  make_run_art(run) unless @run_places[run]
                else
                  @art.sprite_picture(name, Assets::Image.of(picture_named(name)), mixed: mixed.include?(name), number: number,
                                                                                  scene: colors_scene_of_picture(name),
                                                                                  tile_scene: tiles_scene_of_picture(name))
                end
              end
              @tile_runs.each_with_index do |run, number|
                make_run_art(number) unless @run_places[number] || colors_scene_of_run(run) || tiles_scene_of_run(run)
              end
              make_recolored_art(mixed)
            end

            # THE SPRITE ART EVERY SCREEN KEEPS, in a game of a screen's own sprite colours or tiles: all
            # of it placed before any scene takes its copies (Art#sprite_palettes), as the backgrounds'
            # colours are (#make_shared_background_colors). Lists the game changes first, which want
            # a set each, and pictures painted from a list, which keep their tiles for good.
            def reserve_shared_sprite_art(mixed, painted)
              return unless @sprite_colors || @sprite_tiles

              each_recolored_picture do |pose, list, swapped|
                next if scene_of_recolored(pose, list)

                image = Assets::Image.of(picture_named(pose))
                held = held_sprite_palette(list, mixed.include?(pose))
                image = RecoloredImage.new(image: image, recolor: Assets::Recolor.of(image, swapped)) unless held
                @art.reserve_shared_sprite_picture(image, mixed: mixed.include?(pose), held: held)
              end
              @tile_runs.each_with_index { |run, number| make_run_art(number) if @sprite_pictures.include?(run.picture) }
              @sprite_pictures.each do |name|
                next if painted.include?(name) || scene_of_picture(name)

                @art.reserve_shared_sprite_picture(Assets::Image.of(picture_named(name)), mixed: mixed.include?(name))
              end
            end

            # The one scene whose sprites alone show the picture +name+; nil where every screen keeps
            # it. Not a picture painted from a list, whose palette has its colours in its places and
            # whose tiles the game fills.
            def scene_of_picture(name)
              return nil unless @tile_runs.none? { |run| run.picture == name }

              one_scene_of(@objects.values.select { |obj| obj.poses.include?(name) })
            end

            def colors_scene_of_picture(name) = @sprite_colors ? scene_of_picture(name) : nil
            def tiles_scene_of_picture(name) = @sprite_tiles ? scene_of_picture(name) : nil

            # The same for the copy of the picture +pose+ drawn with +list+.
            def scene_of_recolored(pose, list)
              one_scene_of(@objects.values.select { |obj| obj.poses.include?(pose) && obj.recolors.include?(list) })
            end

            def colors_scene_of_recolored(pose, list) = @sprite_colors ? scene_of_recolored(pose, list) : nil
            def tiles_scene_of_recolored(pose, list) = @sprite_tiles ? scene_of_recolored(pose, list) : nil

            # Whether some picture is shown only by the sprites of one scene, so that bringing each
            # scene's tiles in as it takes over can leave room (SNES#build).
            public def sprites_of_one_scene? = @sprite_pictures.any? { |name| scene_of_picture(name) }

            # The same for a list of colours the game changes.
            def colors_scene_of_list(list)
              return nil unless @sprite_colors

              one_scene_of(@objects.values.select { |obj| obj.recolors.include?(list) })
            end

            def one_scene_of(objects)
              scenes = objects.map(&:scene).uniq
              scenes.first if scenes.one?
            end

            # A SPRITE DRAWN WITH OTHER COLOURS (`draw_with`): each of its lists made, ahead of time,
            # into a copy of each of its pictures (Assets::Recolor, the rule the interpreter draws
            # by), with tiles and a palette of its own — two places of a picture's list may share a
            # colour and still swap to two, so no one palette could stand in for another. They are
            # made after every plain picture, whose numbers stay SpriteNames'; #sprite_picture_names
            # names each copy as the picture it copies. A list's colours never change as the game
            # runs: a list told to hold others (`holds`) is not made yet.
            def make_recolored_art(mixed)
              each_recolored_picture do |pose, list, swapped|
                image = Assets::Image.of(picture_named(pose))
                held = held_sprite_palette(list, mixed.include?(pose))
                image = RecoloredImage.new(image: image, recolor: Assets::Recolor.of(image, swapped)) unless held
                @art.sprite_picture([pose, swapped], image, mixed: mixed.include?(pose), held: held,
                                                            scene: colors_scene_of_recolored(pose, list),
                                                            tile_scene: tiles_scene_of_recolored(pose, list))
              end
            end

            # Each picture of each sprite with each list it is drawn with: the picture's name, the
            # list as the game named it, and its colours.
            def each_recolored_picture
              painted = @tile_runs.filter_map(&:picture)
              @objects.each_value do |obj|
                if !obj.recolors.empty? && obj.poses.intersect?(painted)
                  refuse_unmade!("a picture painted from a list and drawn with other colours (`draw_with`)")
                end
                obj.recolors.each do |list|
                  swapped = list.is_a?(Symbol) ? color_list_named(list).colors : list
                  obj.poses.each { |pose| yield pose, list, swapped }
                end
              end
            end

            # The palette of +list+, for a list of sprite colours the game changes (`recolor`), and
            # nil for any other. A sprite drawn with it is one picture whatever the list holds.
            def held_sprite_palette(list, mixed)
              return nil unless list.is_a?(Symbol) && !color_list_named(list).recolors.empty?

              colors = color_list_named(list).colors.drop(1).map { |color| color & 0x7FFF }
              held_palette_or_refuse do
                @art.held_sprite_palette([:sprites, list], colors, mixed: mixed, scene: colors_scene_of_list(list))
              end
            end

            # Reference#exec_color_list_holds: the sets the list can hold, written over its palette. A
            # list nothing is drawn with has no palette, and nothing to show.
            #
            # A list one scene keeps to itself has a palette only while that scene is up, and another
            # scene's colours in it otherwise: the number is kept, and said again as the scene arrives
            # (#emit_scene_colors), so it writes only with its scene up.
            def emit_color_list_holds(node)
              return unless @art.held_palette_of([:sprites, node.name])

              choice = @sprite_color_choices[node.name]
              return emit_sprite_list_write(node.name, node.which) unless choice

              statement(Build.set(choice, node.which))
              other = fresh("not_scene")
              jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(colors_scene_of_list(node.name)))), other)
              emit_sprite_list_write(node.name, Build.var_ref(choice))
              @asm.label(other)
            end

            def emit_sprite_list_write(name, which)
              palette = @art.held_palette_of([:sprites, name])
              list = color_list_named(name)
              sets = [list.colors, *list.recolors].map { |colors| [[@art.sprite_palette_at(palette), colors.drop(1)]] }
              runtime_call("rt_colors_hold", [LongAddress.new(held_colors_label([:sprites, name]) { sets }), which])
            end

            # Each list of sprite colours a scene keeps to itself: the number it was told last, by its
            # name, from power-on the one naming none, as the interpreter keeps it (Reference @held_colors).
            def keep_sprite_color_choices
              lists = @sprite_colors ? @objects.values.flat_map(&:recolors).grep(Symbol).uniq : []
              held = lists.select { |list| !color_list_named(list).recolors.empty? && colors_scene_of_list(list) }
              @sprite_color_choices = held.to_h { |list| [list, keep_local(:"sprite_colors_of_#{list}", start: Build::NO_RECOLOR)] }
            end

            # Reference#exec_background_colors: the background's lists, each written over its palette.
            # In a game of screen colours a scene's background keeps the number it was told, since its
            # scene's colours come in again each time it arrives (#emit_scene_colors).
            def emit_background_colors(node)
              which = node.which
              choice = @background_color_choices[node.name]
              if choice
                statement(Build.set(choice, which))
                which = Build.var_ref(choice)
              end
              for_background(node) { |bg| emit_background_colors_on(which, bg) }
            end

            # In a game of screen colours each declaration has lists of its own, so one the game never
            # draws with others has none to write, and a set of none is a set the routine cannot count.
            def emit_background_colors_on(which, bg)
              return if @screen_colors && Array(bg.recolors).empty?

              label = held_colors_label([:background, bg.object_id]) do
                [nil, *bg.recolors.each_index].map { |step| background_held_set(bg, step) }
              end
              runtime_call("rt_colors_hold", [LongAddress.new(label), which])
            end

            # Each background a scene shows and draws with other colours, in a game of screen colours:
            # the number it was told last, by its name, from power-on the one naming none, as the
            # interpreter keeps it by name (Reference @bg_colors).
            def keep_background_color_choices
              recolored = @screen_colors ? backgrounds_declared.select { |bg| bg.scene && !Array(bg.recolors).empty? } : []
              @background_color_choices = recolored.map(&:name).uniq.to_h do |name|
                [name, keep_local(:"colors_of_#{name}", start: Build::NO_RECOLOR)]
              end
            end

            # Every background of the game, a name two scenes declare once for each.
            def backgrounds_declared = @backgrounds_declared ||= @program.walk.select { |node| node.kind == :background }

            # The scene whose colours +bg+ is drawn from, in a game of screen colours; nil for the sets
            # every screen keeps.
            def colors_scene_of(bg) = @screen_colors ? bg.scene : nil

            # What +bg+'s lists are kept under: a name two scenes declare is two backgrounds with sets
            # of their own, in a game of screen colours.
            def held_lists_key(bg) = [colors_scene_of(bg), bg.name]

            # The one scene whose background shows the tiles of +run+, whose colours it is then drawn
            # from; nil where every screen keeps them, for a run two scenes show as well as one that
            # what every screen shows draws from. A palette a run takes has its colours in its places, so
            # two scenes can only share one by both keeping it.
            def colors_scene_of_run(run) = @screen_colors ? scene_of_run(run) : nil

            # The same for where its tiles are kept, in a game of a screen's own background tiles.
            def tiles_scene_of_run(run) = @scene_background_tiles ? scene_of_run(run) : nil

            def scene_of_run(run)
              return nil if run.picture

              scenes = backgrounds_declared.select { |bg| bg.tiles.intersect?(run.tiles) }.map(&:scene).uniq
              scenes.first if scenes.one?
            end

            # The scene whose tiles +bg+ is drawn from, in a game of a screen's own background tiles;
            # nil for those every screen keeps.
            def tiles_scene_of(bg) = @scene_background_tiles ? bg.scene : nil

            # Whether some background belongs to one scene, so that bringing each scene's tiles in as
            # it takes over can leave room (SNES#build).
            public def backgrounds_of_one_scene? = backgrounds_declared.any?(&:scene)

            # THE COLOURS EVERY SCREEN KEEPS, in a game of screen colours: all of them made before any
            # scene takes its copy (Art#background_palettes): each tile on the maps of what every screen
            # shows, and each one the game changes a cell of it to. A tile of its set that is on neither
            # is never drawn, so it takes no colours. Then the runs a scene keeps to itself, which are
            # the first to take a copy.
            def make_shared_background_colors
              return unless @screen_colors || @scene_background_tiles

              backgrounds_declared.reject(&:scene).each do |bg|
                shown = bg.every_map.flat_map { |map| map.flat_map { |row| Array(row) } }
                changed = @program.walk.select { |node| node.kind == :set_tile && node.name == bg.name }.map(&:tile)
                (shown + changed).uniq.each { |tile| cell_of(bg, tile) if tile.nil? || tile < bg.tiles.length }
              end
              @tile_runs.each_index { |number| make_run_art(number) unless @run_places[number] }
            end

            # A scene taking over, in a game of screen colours: its sets into the colours drawn now and
            # the copy the blank sends, through whatever fade is in force, and the list each of its
            # backgrounds was told to draw with said again over them. They go out in the blank that
            # sends its maps' registers (Runtime::Picture's "Together"), so no frame shows the two out
            # of step.
            def emit_scene_colors(scene, arrival)
              return unless @sprite_colors || (@screen_colors && !arrival.scenery.empty?)

              label = held_colors_label(:scenes) { @scenes.sort_by(&:last).map { |name, _| @art.scene_colors(name) } }
              runtime_call("rt_colors_hold", [LongAddress.new(label), Build.int(@scenes.fetch(scene) - 1)])
              arrival.scenery.each do |bg|
                choice = @background_color_choices[bg.name]
                emit_background_colors_on(Build.var_ref(choice), bg) if choice
              end
              @sprite_color_choices.each do |list, choice|
                emit_sprite_list_write(list, Build.var_ref(choice)) if colors_scene_of_list(list) == scene
              end
            end

            # What a background's palettes hold at its step +step+ (nil for its own colours): each list
            # it is drawn from, by place, as the list named for that step says (Assets::Recolor).
            def background_held_set(bg, step)
              swaps = step && bg.list_swaps(step)
              ((@background_lists || {})[held_lists_key(bg)] || {}).map do |list, (palette, image)|
                swapped = swaps && swaps[list]
                colors = (1...image.colors.length).map { |place| (swapped && swapped[place]) || image.colors[place] }
                [@art.background_palette_at(palette), colors]
              end
            end

            # The palette of the list +image+ is drawn from, in a background the game draws with other
            # colours, and nil in any other.
            def held_background_palette(bg, image)
              return nil if Array(bg.recolors).empty?

              list = image.list_drawn_from
              colors = image.colors.drop(1).map { |color| color & 0x7FFF }
              palette = @art.held_background_palette([:backgrounds, *held_lists_key(bg), list], colors, scene: colors_scene_of(bg))
              ((@background_lists ||= {})[held_lists_key(bg)] ||= {})[list] = [palette, image]
              palette
            end

            # THE PALETTE OF A RUN ON A BACKGROUND THE GAME DRAWS WITH OTHER COLOURS: the one its list has
            # on that background, shared with the pictures drawn from the list, so a walk of colours
            # reaches them all. A run's pixels are places in its list already. A palette is one
            # background's, so a run two such backgrounds show is not made.
            def held_palette_of_run(run)
              shown = backgrounds_declared.select { |bg| bg.tiles.intersect?(run.tiles) && !Array(bg.recolors).empty? }
              return nil if shown.empty?

              names = shown.map(&:name).uniq
              refuse_unmade!("a tile painted from a list on two backgrounds drawn with other colours") unless names.one?
              held_background_palette(shown.first, run)
            end

            # A list of sprite colours that changes keeps a palette, and the console has eight on a
            # screen. Too many for the whole game is not yet the end of it (SNES#build).
            def held_palette_or_refuse
              yield
            rescue Art::TooManySpriteColors
              raise
            rescue Art::TooMuch
              refuse_unmade!("more lists of colours changing as the game runs than a Super Nintendo has palettes")
            end

            # The label of the table of sets (Runtime::Tint's rt_colors_hold) kept under +key+, worked
            # out by the block when the art is written, by when every palette of it is known.
            def held_colors_label(key, &sets)
              @held_colors ||= {}
              @held_colors[key] ||= ["art held colors #{@held_colors.length}", sets]
              @held_colors[key].first
            end

            # Each table of sets as data for the Linker.
            def write_held_colors(data)
              (@held_colors || {}).each_value do |label, sets|
                worked_out = sets.call
                data.label(label)
                data.data_words(worked_out.length)
                worked_out.each_index do |set|
                  data.data_longs("#{label} set #{set}")
                  data.data_bytes(0)
                end
                worked_out.each_with_index do |palettes, set|
                  data.label("#{label} set #{set}")
                  data.data_words(palettes.length)
                  palettes.each do |at, colors|
                    shown = colors.map { |color| color & 0x7FFF }
                    data.data_words(at, *shown.fill(0, shown.length...Runtime::Tint::PALETTE_COLORS))
                  end
                end
              end
            end

            # A picture drawn with another list: its colours swapped pixel by pixel.
            RecoloredImage = Data.define(:image, :recolor) do
              def width = image.width
              def height = image.height
              def drawn_at?(at) = image.drawn_at?(at)
              def color_at(at) = recolor.color_for(at, image.color_at(at))
              def pieces = nil # cut from its swapped pixels, since its pieces name the first list's colours
            end

            def color_list_named(name)
              @color_lists ||= by_kind(:color_list)
              @color_lists.fetch(name) { raise LoweringError, "the list of colours #{name.inspect} is drawn with and never declared" }
            end

            # The picture each picture of the art is, by number, as SpriteNames numbers it: a plain
            # picture its own, a copy in other colours (#make_recolored_art) the one it copies.
            def sprite_picture_names
              @art.sprite_pictures.map do |name, _|
                @sprite_names.picture_number(name.is_a?(Array) ? name.first : name)
              end
            end

            # Run +number+'s tiles (SNES::Art#background_run, #sprite_run_picture), and where in video
            # RAM the first is: tiles are 16 words each (Runtime::Picture's layout).
            def make_run_art(number)
              run = @tile_runs.fetch(number)
              if run.picture
                in_table = @sprite_pictures.index(run.picture) || @art.sprite_pictures.length
                picture = @art.sprite_run_picture(run.picture, run.width, run.height, run.colors, number: in_table)
                @run_places[number] = Runtime::Picture::SPRITE_TILES + (picture.pieces.first.tile * Art::TILE_BYTES / 2)
              elsif run.tile_side == BIG_TILE
                make_big_run_art(run, number)
              else
                first, palette = @art.background_run(run.colors, run.tiles.length, held: held_palette_of_run(run), scene: colors_scene_of_run(run), tile_scene: tiles_scene_of_run(run))
                run.tiles.each_with_index { |image, k| @run_cells[image] = [first + k, palette] }
                @run_places[number] = Runtime::Picture::BG_TILES + (first * Art::TILE_BYTES / 2)
                @held_strips << [run.tiles.length * Art::TILE_BYTES, @run_places[number], 0] if run.held_in
              end
            end

            # A run of big tiles, and the two strips each is copied in, as [bytes, where in video RAM,
            # how far into the picture]: its quarters are kept left to right and then down.
            def make_big_run_art(run, number)
              firsts, palette = @art.background_big_run(run.colors, run.tiles.length, held: held_palette_of_run(run), scene: colors_scene_of_run(run), tile_scene: tiles_scene_of_run(run))
              words_a_tile = Art::TILE_BYTES / 2
              firsts.each_with_index do |first, k|
                @run_cells[run.tiles.fetch(k)] = [first, palette]
                place = Runtime::Picture::BG_TILES + (first * words_a_tile)
                top = k * 4 * Art::TILE_BYTES
                @held_strips << [2 * Art::TILE_BYTES, place, top]
                @held_strips << [2 * Art::TILE_BYTES, place + (16 * words_a_tile), top + (2 * Art::TILE_BYTES)]
              end
              @run_places[number] = Runtime::Picture::BG_TILES + (firsts.first * words_a_tile)
            end

            # A `screen` other than the game's own that says a backdrop the game's does not, somewhere
            # it cannot come up by: on a painted screen, or anywhere but the top of a scene.
            def refuse_backdrops_of_its_own!
              handover = IR::SceneHandover.of(@program)
              game_backdrop = handover.game_backdrop
              said = @program.walk.select { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }
              return if said.empty? || (!painted? && said.all? { |node| handover.scene_screen?(node) })

              refuse_unmade!("a scene that says a backdrop of its own (`screen ... backdrop:`)")
            end

            # Whether a scene of +program+ says a backdrop the game's does not, which colour 0 is
            # changed to as it takes over (Runtime::Tint's rt_backdrop_hold).
            def self.scene_backdrops?(program)
              return false if Lowering::Paint.painted?(program)

              handover = IR::SceneHandover.of(program)
              handover.scene_screens.any? { |_, screen| screen.backdrop && screen.backdrop != handover.game_backdrop }
            end

            # A scene taking over, in a game whose scenes differ in their backdrop: colour 0 changed
            # to its own, or the game's where it says none. It goes out with the scene's colours and
            # maps (Runtime::Picture's "Together"), through whatever fade is in force.
            def emit_scene_backdrop(arrival)
              return unless Picture.scene_backdrops?(@program)

              runtime_call("rt_backdrop_hold", [Build.int(arrival.backdrop & 0x7FFF)])
            end

            def refuse_unmade!(what)
              raise NotMadeYet.new("This game has #{what}. The Super Nintendo build does not make that yet. To fix " \
                                   "this, build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "the picture")
            end

            # The two layers a background can be given.
            BACKGROUND_LAYERS = 2

            # The art, and each sprite's table of pictures, as sections for the Linker.
            def art_sections
              data = W65816.new("art", holds: ART)
              data.label("art background tiles bytes")
              data.data_words(@art.background_tile_data(opening_scene).bytesize)
              data.label("art sprite tiles bytes")
              data.data_words(@art.sprite_tile_data(opening_scene).bytesize)
              unless painted? # Lowering::Paint's colours, then
                data.label("art colors")
                data.data_bytes(@art.cgram.bytes)
              end
              data.label("art sprite pictures")
              pictures = @art.sprite_pictures.values.sort_by(&:number)
              data.data_longs(pictures.map { |picture| pieces_label(picture.number) })
              pictures.each do |picture|
                data.label(pieces_label(picture.number))
                data.data_words(picture.pieces.length)
                picture.pieces.each do |piece|
                  data.data_words(piece.dx, piece.dy,
                                  piece.tile | (piece.palette << 9) | SPRITE_IN_FRONT)
                  data.data_words(piece.big ? Runtime::Picture::SPRITE_SIZE_BIT : 0) if sprite_squares?
                end
              end
              write_held_colors(data)
              data.label("art grids")
              @art.grids.each do |grid|
                data.data_longs(grid_label(grid.number))
                data.data_bytes(0)
                data.data_words(grid.bytes.bytesize, grid.size_bits, grid.columns)
              end
              write_scene_background_tile_tables(data)
              data.label("art tile runs")
              @tile_runs.each_with_index do |run, number|
                list = @lists.fetch(run.list).first
                staging = @memory[Runtime::Picture.tile_run_staging(number)]
                data.data_words(list & 0xFFFF, list >> 16)
                if run.held_in
                  data.data_longs(table_label(run.held_in))
                  data.data_bytes(0)
                else
                  data.data_words(staging & 0xFFFF, staging >> 16)
                end
                data.data_words(@run_places[number], Picture.tile_run_bytes(@program)[number] / 32, Picture.tile_run_bytes(@program)[number], 0)
              end
              unless @held_strips.empty?
                data.label("art held strips")
                @held_strips.each { |strip| data.data_words(*strip) }
              end
              @pose_tables.each do |(obj, swapped), label|
                data.label(label)
                # Each picture by the number Art made it with ("art sprite pictures"' order), or its
                # copy in the list of colours +swapped+.
                data.data_words(obj.poses.length,
                                *obj.poses.map { |pose| @art.sprite_pictures.fetch(swapped ? [pose, swapped] : pose).number })
              end
              [data.section, *bytes_section("art background tiles", @art.background_tile_data(opening_scene)),
               *bytes_section("art sprite tiles", @art.sprite_tile_data(opening_scene)), *scene_sprite_tile_sections,
               *scene_background_tile_sections, *@art.grids.map { |grid| bytes_section(grid_label(grid.number), grid.bytes) },
               *(painted? ? paint_sections : []), *collision_sections]
            end

            # The scene first declared, whose own tiles go in at power-on with the rest: the game opens
            # on it, so the first pass has nothing to load and lands on the frame it would. A game that
            # opens on another loads that one's as any scene does.
            def opening_scene = @scenes.min_by(&:last)&.first

            # Which scene's own tiles are in video memory, in a game that keeps tiles by scene.
            def keep_scene_tiles_up
              @scene_tiles_up = keep_local(:scene_tiles_up, start: @scenes.fetch(opening_scene)) if @sprite_tiles || @scene_background_tiles
            end

            # A scene taking over brings in its tiles, unless they are the ones in video memory.
            def emit_scene_tiles(scene)
              return unless @scene_tiles_up

              number = Build.int(@scenes.fetch(scene))
              same = fresh("scene_tiles_up")
              jump_unless(Build.binop(:!=, Build.var_ref(@scene_tiles_up), number), same)
              statement(Build.set(@scene_tiles_up, number))
              emit_scene_sprite_tiles(scene)
              emit_scene_background_tiles(scene)
              @asm.label(same)
            end

            # What each scene brings into video memory as it takes over (#emit_scene_sprite_tiles).
            def scene_sprite_tile_sections
              return [] unless @sprite_tiles

              @scenes.keys.filter_map do |scene|
                _, bytes = @art.scene_sprite_tiles(scene)
                bytes_section(scene_sprite_tiles_label(scene), bytes) if bytes
              end
            end

            def scene_sprite_tiles_label(scene) = "art sprite tiles of #{scene}"

            # A scene taking over, in a game of a screen's own sprite tiles: the ones it keeps to itself
            # go in over the last scene's, in the blanks after this pass (Runtime::Picture's
            # rt_scene_sprite_tiles).
            def emit_scene_sprite_tiles(scene)
              return unless @sprite_tiles

              first, bytes = @art.scene_sprite_tiles(scene)
              return unless first

              place = Runtime::Picture::SPRITE_TILES + (first * Art::TILE_BYTES / 2)
              runtime_call("rt_scene_sprite_tiles", [LongAddress.new(scene_sprite_tiles_label(scene)), Build.int(bytes.bytesize), Build.int(place)])
            end

            # What each scene brings in of its background tiles (#emit_scene_background_tiles).
            def scene_background_tile_sections
              return [] unless @scene_background_tiles

              @scenes.keys.filter_map do |scene|
                _, bytes = @art.scene_background_tiles(scene)
                bytes_section(scene_background_tiles_label(scene), bytes) if bytes
              end
            end

            def scene_background_tiles_label(scene) = "art background tiles of #{scene}"
            def scene_background_table_label(scene) = "art background table of #{scene}"

            # For each scene where its background tiles are on the cartridge, how many bytes and where
            # they go, written last since a game can draw a tile no map shows (`set_tile`).
            def write_scene_background_tile_tables(data)
              return unless @scene_background_tiles

              @scenes.each_key do |scene|
                first, bytes = @art.scene_background_tiles(scene)
                data.label(scene_background_table_label(scene))
                bytes ? data.data_longs(scene_background_tiles_label(scene)) : data.data_bytes(0, 0, 0)
                data.data_bytes(0)
                data.data_words(bytes.to_s.bytesize, Runtime::Picture::BG_TILES + (first.to_i * Art::TILE_BYTES / 2))
              end
            end

            # A scene taking over, in a game of a screen's own background tiles: the ones it keeps to
            # itself go in over the last scene's, with the picture off (Runtime::Picture's
            # rt_scene_background_tiles).
            def emit_scene_background_tiles(scene)
              return unless @scene_background_tiles

              runtime_call("rt_scene_background_tiles", [LongAddress.new(scene_background_table_label(scene))])
            end

            ART = W65816::Holding.new(what: "the game's pictures", fix: "use fewer different pictures and maps")

            # A sprite row's attributes, the high byte of its tile word: in front of every background
            # (priority 3). A sprite behind a background has the difference from its own priority
            # (#sprite_depths) taken off as it is placed.
            SPRITE_IN_FRONT = 0x3000

            # The priority bits of a sprite row.
            SPRITE_PRIORITY_SHIFT = 12

            # SPRITES IN LAYERS, among the backgrounds (#assign_background_layers has put each
            # background on its layer): each sprite's priority, by its name, from the backgrounds
            # in front of it on the screens it is on (IR::Stacking's depths, per screenful) — 3 for
            # none, 2 for BG1 alone, which is then drawn high (Art::CELL_IN_FRONT), 1 for BG2. Empty when
            # every sprite is in front of every background, as in a game that names no layers. A sprite
            # that can be put in other layers has one by each name it has a depth by (#depth_names).
            def sprite_depths
              @sprite_depths ||= begin
                found = {}
                Stacking.screenfuls(@program).each do |screenful|
                  scenery = screenful.scenery.reject(&:bar?)
                  screenful.objects.each do |obj|
                    depth_names(obj).each do |name|
                      level = screenful.depths[name]
                      front = scenery.select { |bg| screenful.depths.of_scenery(bg) > level }.map { |bg| layer_of(bg) }
                      priority = if front.include?(1) then 1
                                 elsif front.include?(0) then 2
                                 else 3
                                 end
                      if found.fetch(name, priority) != priority
                        refuse_unmade!("a sprite behind a background on one screen and in front of it on another")
                      end
                      if priority != 3 && screenful.scenery.any?(&:bar?)
                        refuse_unmade!("a status bar beside a sprite behind a background")
                      end
                      found[name] = priority
                    end
                  end
                end
                found.reject! { |_, priority| priority == 3 }
                found
              end
            end

            # Whether +bg+'s cells are drawn high, in front of the sprites of priority 2.
            def cells_in_front?(bg) = layer_of(bg).zero? && sprite_depths.value?(2)

            def pieces_label(number) = "art pieces #{number}"
            def grid_label(number) = "art grid #{number}"

            def bytes_section(label, bytes)
              asm = W65816.new(label, holds: ART)
              asm.label(label)
              asm.data_bytes(bytes.bytes)
              asm.section
            end

            # The colour math a see-through layer needs (#refuse_unmade_see_through!), as
            # [the layers it mixes, the layers behind them] a bit each, BG1's first; nil for none.
            attr_reader :see_through_layers

            # The layers bent, in #bends' order, whose line tables the runtime makes.
            def bent_layers = painted? ? [] : bends.map { |bend| layer_of(background_declared_for(bend)) }.uniq

            # Whether the game's bends are kept as a step for each band (Runtime::Picture, "A bend that
            # says a thing about whole bands of rows"): every bend has bands, few enough to keep.
            def bends_by_bands?
              bend_bands.all? && bend_bands.all? { |firsts| band_steps(firsts).sum(&:length) <= Runtime::Picture::MOST_BAND_STEPS }
            end

            # BGMODE'S SIZE BITS for the layers drawn from 16×16 tiles: BG1's is bit 4, BG2's bit 5, told
            # at power-on. A layer whose scenes differ is told as each takes over (#emit_tile_sizes_for),
            # and is not among these. Only a scene can differ: what every screen shows has one size.
            def big_tile_layers
              return 0 if painted?

              @big_tile_layers ||= @layers.group_by { |_, layer| layer }.sum do |layer, held|
                sizes = held.map { |bg, _| bg.tile_w }.uniq
                sizes == [BIG_TILE] ? BIG_TILE_BIT << layer : 0
              end
            end

            # Whether a layer shows 16×16 tiles in one scene and 8×8 in another.
            def tile_sizes_turn? = !painted? && !layers_of_two_sizes.empty?

            # Whether +program+ could have such a layer, so the runtime keeps room to be told: which
            # layer a background is on is worked out later, and two sizes on two layers ask for the
            # room and never use it.
            def self.two_tile_sizes?(program)
              backgrounds = program.walk.select { |node| node.kind == :background }
              backgrounds.any? { |bg| !bg.scene.nil? } && backgrounds.map(&:tile_w).uniq.length > 1
            end

            BIG_TILE_BIT = 0x10

            private

            def layers_of_two_sizes
              @layers_of_two_sizes ||= @layers.group_by { |_, layer| layer }.filter_map do |layer, held|
                layer if held.map { |bg, _| bg.tile_w }.uniq.length > 1
              end
            end

            # A scene taking over: BGMODE told the size of the tiles it shows on a layer whose scenes
            # differ, in the same blank as its maps' registers (Runtime::Picture::TILE_SIZES), so no
            # frame shows a map with the other size's setting.
            def emit_tile_sizes_for(arrival)
              return unless tile_sizes_turn?

              shown = arrival.scenery.select { |bg| bg.tile_w == BIG_TILE }.map { |bg| layer_of(bg) }
              bits = (layers_of_two_sizes & shown).sum { |layer| BIG_TILE_BIT << layer }
              @asm.lda(Runtime::Picture::TILED_MODE | big_tile_layers | bits)
              @asm.sta(@asm.abs(@memory[Runtime::Picture::TILE_SIZES]))
            end

            def by_kind(kind) = @program.walk.select { |node| node.kind == kind }.to_h { |node| [node.name, node] }

            def picture_named(name)
              @pictures.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
            end

            # --- the screen and the backgrounds ---

            # A tiled screen is the one the console is set up for at power-on.
            def emit_screen(_node) = nil

            # Reference#exec_background: put up, showing from its corner (Reference#put_up_background).
            # A scene's own goes up as the scene takes over instead (#emit_scene_arrival).
            def emit_background(node)
              return if @handover.on_arrival?(node)

              emit_put_up(node)
            end

            def emit_put_up(bg)
              runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, 0).number), Build.int(1)])
              # A status bar put up shows from the top it was declared with (Reference#bar_top_shown).
              runtime_call("rt_bar_place", [Build.int(layer_of(bg)), Build.int(bg.bar_top)]) if bg.bar?
              [@put_up_this_pass&.fetch(layer_of(bg)), (@bar_up_this_pass if bg.bar?)].compact.each { |note| statement(Build.set(note, 1)) }
            end

            # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME
            # (Reference#put_up_background), and the place the game keeps for its view, or the top it
            # keeps for a status bar, is written at the end of the pass (IR::Frames
            # .loop_in_console_order), after the put-up. So a put-up notes itself for the rest of its
            # pass, a note for each layer, and the write at the end of it leaves the background or bar
            # where it was put up. The wait forgets the notes (#emit_corners_forgotten), and the next
            # pass's write moves it.
            def keep_corner_notes
              placed = ->(kind) { @program.walk.any? { |node| node.kind == kind && placed_at_pass_end?(node) } }
              if placed.call(:scroll_background)
                @put_up_this_pass = LAYERS.to_h { |layer| [layer, keep_local(:"put_up_this_pass_#{layer}")] }
              end
              @bar_up_this_pass = keep_local(:bar_up_this_pass) if placed.call(:place_bar)
            end

            # The two layers a background can be on.
            LAYERS = [0, 1].freeze

            # The notes forgotten at a wait: the pass that put a background up has ended.
            def emit_corners_forgotten
              [*@put_up_this_pass&.values, @bar_up_this_pass].compact.each { |note| statement(Build.set(note, 0)) }
            end

            # +node+'s write, unless it is written at the end of a pass that put its background or bar
            # up (+note+, #keep_corner_notes).
            def emit_unless_put_up(node, note)
              return yield unless note && placed_at_pass_end?(node)

              held = fresh("held_at_corner")
              jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
              yield
              @asm.label(held)
            end

            # WHICH OF THE TWO LAYERS EACH BACKGROUND IS ON (#assign_background_layers). A scene's own
            # scenery is in front of the scenery every screen shows, as the interpreter paints it over
            # what is up already, and within each the one drawn last is in front — the one declared
            # last, or the one in the front-most layer the game's `layers` name (IR::Stacking, which
            # IR::SceneHandover hands the scenery over in the order of): so the scenes' own take the
            # front layers, BG1 first, as many as the scene with the most has, and the scenery every
            # screen shows the layers behind those. So a stack that puts a scene's own background
            # behind one every screen shows is not made yet. (Every sprite is in front of every
            # background, SPRITE_IN_FRONT: a background in front of a sprite needs the sprite in a
            # layer, which #refuse_unmade_picture! refuses.)
            def assign_background_layers
              @layers = {}.compare_by_identity
              always = @handover.always_up.scenery
              own = @scenes.keys.map { |scene| @handover.arrival(scene).scenery }
              @scene_layers = own.map(&:length).max || 0
              if always.length + @scene_layers > BACKGROUND_LAYERS
                refuse_unmade!("more than two backgrounds on the screen at once")
              end
              @scene_bars = own.flatten.any?(&:bar?)
              refuse_unmade_stacking!(always)
              refuse_unmade_bends!
              always.each_with_index { |bg, i| @layers[bg] = @scene_layers + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
              refuse_unmade_see_through!
            end

            def layer_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no layer" }

            # A stack the layers' order cannot show: a scene's own background behind one every screen
            # shows (see #assign_background_layers).
            def refuse_unmade_stacking!(always)
              @scenes.each_key do |scene|
                own = @handover.arrival(scene).scenery
                drawn = @handover.showing(scene).select { |bg| (always + own).any? { |up| up.equal?(bg) } }
                next if drawn.map(&:object_id) == (always + own).map(&:object_id)

                refuse_unmade!("a scene's own background in a layer behind a background every screen shows")
              end
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names: the one by
            # that name, or — where several scenes each declare their own by one name — the one of the
            # scene whose routine is being lowered, or the one every screen shows.
            def background_declared_for(node)
              declared = @program.walk.select { |bg| bg.kind == :background && bg.name == node.name }
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" if declared.empty?
              return declared.first if declared.length == 1

              own = @lowering_scene && @handover.arrival(@lowering_scene).scenery.find { |bg| bg.name == node.name }
              own || @handover.always_up.scenery.find { |bg| bg.name == node.name }
            end

            # +node+'s change made to the background it names (#background_declared_for), yielded
            # to the block. Where that is not known while the game is built — a change outside every
            # scene's routine, to a name several scenes declare — the change is made to the one of
            # the scene up when it runs, each scene's its own branch.
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

            # A scene taking over (Lowering#emit_scene): the tiles its scenery and its sprites paint
            # from lists copied in again, as each list is now; what it shows of its own goes up from
            # its corner, as declared, with every map it chooses back at the first; and the layers its
            # own scenery does not use, which the scene before may have used, come down
            # (IR::SceneHandover). The scenery every screen shows stays as it is.
            def emit_scene_arrival(scene)
              return if painted?

              arrival = @handover.arrival(scene)
              emit_scene_tiles(scene)
              (arrival.painted_tiles + arrival.painted_pictures).each { |run| emit_tile_run_copy(run.name) }
              emit_see_through_for_scene(scene)
              emit_scene_backdrop(arrival)
              emit_scene_colors(scene, arrival) if @scene_layers.zero?
              return if @scene_layers.zero?

              emit_layers_straight_for(arrival)
              emit_tile_sizes_for(arrival)
              emit_scene_colors(scene, arrival)
              arrival.map_choices.each { |var| store_number(place_of(var), 0) }
              arrival.scenery.each { |bg| emit_put_up(bg) }
              ((0...@scene_layers).to_a - arrival.scenery.map { |bg| layer_of(bg) }).each do |layer|
                runtime_call("rt_background_put_up", [Build.int(layer), Build.int(empty_grid.number), Build.int(1)])
              end
              runtime_call("rt_bar_gone", []) if scene_bars? && arrival.scenery.none?(&:bar?)
            end

            # The layers some scene bends and the one taking over does not: their rows go straight.
            def emit_layers_straight_for(arrival)
              bent = bends.reject { |bend| scenes_showing(bend).nil? }.map { |bend| background_declared_for(bend) }
              return if bent.empty?

              up = bent.select { |bg| scenery_holds?(arrival.scenery, bg) }
              straight = bent.map { |bg| layer_of(bg) }.uniq - up.map { |bg| layer_of(bg) } # two scenes can bend one layer
              @asm.lda(straight.sum { |layer| 1 << layer })
              @asm.sta(@asm.abs(@memory[Runtime::Picture::LAYERS_STRAIGHT]))
            end

            # Whether a scene of the game puts up a status bar of its own, which leaves as the next
            # scene takes over (Runtime::Picture's rt_bar_gone).
            public def scene_bars? = @scene_bars

            # A grid of nothing, put up on a layer to take down what was there.
            def empty_grid = @empty_grid ||= @art.grid(Array.new(32) { Array.new(32) }, 32, 32)

            # The background's map number +which+ as a grid of cells (SNES::Art#grid).
            def grid_of(bg, which)
              @grids[[bg.object_id, which]] ||= begin
                map = bg.every_map.fetch(which)
                columns, rows = TileMap.grid(map)
                cells = map.map { |row| Array(row).map { |tile| cell_of(bg, tile) } }
                @art.grid(cells, columns, rows, in_front: cells_in_front?(bg))
              end
            end

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              name = bg.tiles.fetch(tile)
              @run_cells.fetch(name) do
                image = Assets::Image.of(picture_named(name))
                held = held_background_palette(bg, image)
                places = { held: held, scene: colors_scene_of(bg), tile_scene: tiles_scene_of(bg) }
                bg.tile_w == BIG_TILE ? @art.background_big_cell(image, **places) : @art.background_cell(image, **places)
              end
            end

            # The side of a background tile the console draws itself, beside 8×8 (BGMODE's size bits).
            BIG_TILE = 16

            # Reference#exec_scroll_background.
            def emit_scroll_background(node) = for_background(node) { |bg| emit_scroll_background_on(node, bg) }

            def emit_scroll_background_on(node, bg)
              emit_unless_put_up(node, @put_up_this_pass&.fetch(layer_of(bg))) do
                runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
              end
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map.
            def emit_set_tile(node) = for_background(node) { |bg| emit_set_tile_on(node, bg) }

            def emit_set_tile_on(node, bg)
              return if node.tile && node.tile >= bg.tiles.length

              columns, rows = TileMap.size_of(bg.every_map.first)
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
              tile, palette = cell_of(bg, node.tile)
              word = tile ? tile | (palette << Art::PALETTE_SHIFT) | (cells_in_front?(bg) ? Art::CELL_IN_FRONT : 0) : 0
              runtime_call("rt_set_cell", [Build.int(layer_of(bg)), Build.var_ref(column), Build.var_ref(row), Build.int(word)])
              @asm.label(outside)
            end

            # Reference#exec_place_bar: a background that is not a status bar has no top to place.
            def emit_place_bar(node)
              for_background(node) do |bg|
                next unless bg.bar?

                runtime_call("rt_bar_covers", [node.covers]) if node.covers
                emit_unless_put_up(node, @bar_up_this_pass) { runtime_call("rt_bar_place", [Build.int(layer_of(bg)), node.top]) }
              end
            end

            # --- tiles painted from a list ---

            # Reference#exec_copy_tiles: the run's list copied into its tiles, shown with this pass.
            def emit_copy_tiles(node) = emit_tile_run_copy(node.name)

            # The run named +name+ copied from its list (Runtime::Picture's rt_tile_run_copy), by the
            # number the runtime knows it by.
            def emit_tile_run_copy(name)
              number = @tile_runs.index { |run| run.name == name }
              return emit_held_run_owed(number) if @tile_runs[number].held_in

              runtime_call(@tile_runs[number].console_format ? "rt_tile_run_straight" : "rt_tile_run_copy", [Build.int(number)])
            end

            # A run held in the cartridge has nothing to convert, so being owed a copy is all there is.
            def emit_held_run_owed(number)
              @asm.lda(1)
              @asm.sta(@asm.abs(@memory[Runtime::Picture::TILE_RUNS_OWED] + (number * 2)))
            end

            # A picture chosen for a run held in the cartridge (Picture.held_runs): how far into the
            # table it starts, in a word the blank's copy reads. The table is one bank's, so the
            # copying engine can read from any of it. Held inside the table, as a list copy is.
            def emit_held_picture_choice(node, number)
              table = @tables.fetch(node.table)
              if split?(table)
                raise LoweringError, "tile_pictures :#{@tile_runs[number].name} holds more pictures than a bank of the " \
                                     "Super Nintendo cartridge. To fix this, split it into smaller groups."
              end

              value(Build.clamped(node.at, Build.int(0), Build.int(table.values.length - node.count)))
              @asm.lda(@asm.direct(Memory.register(0)))
              @asm.sta(@asm.abs(@memory[Runtime::Picture.tile_run_held(number)]))
            end

            # The run held in the cartridge that shows the list +name+, by its number, or nil.
            def held_run_of_list(name) = @tile_runs.index { |run| run.held_in && run.list == name }

            # What a table holds as the cartridge keeps it: a table of pictures held for the copying
            # engine in the console's form, and any other as the game gave it.
            def values_kept(table)
              @tile_runs.any? { |run| run.held_in == table.name } ? @art.in_console_form(table.values) : table.values
            end

            # Reference#exec_copy_owed_tiles: every run whose bit of the masks is set, in the order
            # they were declared.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                skip = fresh("run_not_owed")
                owed = Build.binop(:&, Build.var_ref(node.masks.fetch(i / per)), Build.int(1 << (i % per)))
                jump_unless(Build.binop(:!=, owed, Build.int(0)), skip)
                emit_tile_run_copy(name)
                @asm.label(skip)
              end
            end

            # --- a layer half see-through ---

            # THE LAYER SEEN THROUGH (`layer ..., transparency:`), on the console's colour math: every
            # layer on the main screen as ever, the layers behind the see-through one on the sub
            # screen too, and the math told to add the sub screen to the see-through layer's pixels
            # and halve the sum, on its pixels alone (Runtime::Picture's power-on). So a sprite in
            # front of it, and its own see-through pixels (where what is behind is on top of the main
            # screen, with no math) stay solid, as on the interpreter. The console only halves, so
            # the amounts must come to an even half, eight sixteenths each (IR::SeeThrough.weights),
            # which #refuse_see_through_amounts! has seen to; and where the sub screen has nothing,
            # the console adds its fixed colour instead and does not halve, so a background that
            # covers every pixel must be behind the layer.
            #
            # A LAYER A SCENE OWNS, or one over a background a scene puts up, is on that scene alone:
            # the scenes showing it share one sub screen, since that is told once at power-on, and
            # each scene taking over tells the math what it has to mix, which for any other scene is
            # nothing (#emit_see_through_for_scene).
            def refuse_unmade_see_through!
              layers = SeeThrough.layers(@program)
              return if layers.empty?

              layer = layers.first
              parts = Picture.see_through_parts(@program, layer)
              seen_through = parts.seen_through
              sprites = parts.sprites
              @see_through_sprites = sprites.map(&:name)
              return if seen_through.empty? && sprites.empty?
              refuse_unmade!("a see-through layer of both backgrounds and sprites") unless seen_through.empty? || sprites.empty?

              behind = see_through_behind_in_its_scenes(parts)
              # Adding, an empty sub screen adds the fixed colour, nothing: the layer whole, as the
              # interpreter shows it over the black backdrop. Only halving needs something behind.
              adds = added_to_what_is_behind?(layer)
              raise LoweringError, see_through_uncovered_message(layer) unless adds || behind.any? { |bg| covers_screen?(bg) }

              bits = ->(bgs) { bgs.sum { |bg| 1 << layer_of(bg) } }
              mixed, under = if seen_through.empty?
                               # The sprites' pixels mixed, with the scenery alone behind them.
                               [SPRITES_BIT, bits.call(behind)]
                             else
                               # The backgrounds' pixels mixed, with the scenery and the
                               # sprites behind them; a sprite in front is not on top of a
                               # mixed pixel anywhere it is drawn, so has no say.
                               [bits.call(seen_through), bits.call(behind) | SPRITES_BIT]
                             end
              @see_through_layers = [adds ? mixed : mixed | Runtime::Picture::MATH_HALVES, under]
            end

            SeeThroughParts = Data.define(:seen_through, :sprites, :behind)

            # What a see-through +layer+ is made of, and the backgrounds behind it, of every scene.
            def self.see_through_parts(program, layer)
              picture = Stacking.picture(program)
              scenery = picture.scenery.reject(&:bar?)
              at = picture.stack.index(layer.name)
              SeeThroughParts.new(seen_through: scenery.select { |bg| bg.layer == layer.name },
                                  sprites: picture.objects.select { |obj| obj.layer == layer.name },
                                  behind: scenery.select { |bg| bg.layer.nil? || picture.stack.index(bg.layer) < at })
            end

            # Whether +program+'s see-through layer is on some scenes only, or over a background only
            # some scenes put up, so the colour math changes as scenes take over.
            def self.see_through_in_scene?(program)
              layer = SeeThrough.layers(program).first
              return false unless layer

              parts = see_through_parts(program, layer)
              own = parts.seen_through + parts.sprites
              !own.empty? && (own + parts.behind).any?(&:scene)
            end

            # The backgrounds behind the see-through layer on the scenes that show it, one lot, and
            # which those scenes are (@see_through_scenes, nil for a layer every screen shows alike).
            def see_through_behind_in_its_scenes(parts)
              return parts.behind unless Picture.see_through_in_scene?(@program)

              own = parts.seen_through + parts.sprites
              names = own.filter_map(&:scene).uniq
              showing = names.empty? ? @scenes.keys : names
              lots = showing.map { |scene| parts.behind.select { |bg| bg.scene.nil? || bg.scene == scene } }
              unless lots.map { |lot| lot.map { |bg| layer_of(bg) }.sort }.uniq.one?
                refuse_unmade!("a see-through layer over backgrounds on different layers in different scenes")
              end
              @see_through_scenes = showing.map { |scene| @scenes.fetch(scene) }
              lots.first
            end

            # A scene taking over: the colour math told what this scene has to mix, its layer's
            # amount as the game left it, or nothing at all on a scene that does not show the layer.
            def emit_see_through_for_scene(scene)
              return unless @see_through_scenes

              shows = @see_through_scenes.include?(@scenes.fetch(scene))
              runtime_call("rt_see_through_math", [shows ? see_through_math_now : Build.int(0)])
            end

            # What the colour math is to be told for the amount the layer stands at now.
            def see_through_math_now
              on = Build.binop(:!=, SeeThrough.layers(@program).first.behind.copy, Build.int(0))
              Build.binop(:*, on, Build.int(@see_through_layers.first))
            end

            # Whether +layer+ shows the whole of itself over the whole of what is behind it, which the
            # console's colour math does with no halving. What is behind may be a number the game
            # works out, for a layer it turns solid: that is the one amount it can change, and it is
            # 100 or 0 (#emit_see_through_amount).
            def added_to_what_is_behind?(layer)
              return false if layer.split || layer.shows.kind != :int

              whole = SeeThrough::STEPS
              SeeThrough.nearest_steps(layer.shows.value) == whole &&
                (layer.behind.kind != :int || SeeThrough.nearest_steps(layer.behind.value) == whole)
            end

            # Whether +program+ tells a status bar to cover sprites (Runtime::Picture's rt_bar_covers).
            def self.bar_covers_sprites?(program)
              program.walk.any? { |node| node.kind == :place_bar && node.covers }
            end

            # Whether +program+ turns a see-through layer solid as it runs, which the runtime then keeps
            # what the colour math is told in (Runtime::Picture's rt_see_through_math).
            def self.see_through_turns_solid?(program)
              SeeThrough.layers(program).any? { |layer| !layer.split && layer.behind.kind != :int } ||
                see_through_in_scene?(program)
            end

            # Reference#exec_see_through: the colour math on while what is behind shows, and off, the
            # layer solid, at nought. An amount between shows as 100 does: the console adds or it does
            # not. It is told in the next blank, with the frame's sprites.
            def emit_see_through_amount(node)
              return unless @see_through_layers
              return emit_see_through_amount_while_up unless @see_through_scenes.nil?

              runtime_call("rt_see_through_math", [see_through_math_now])
            end

            # ...and on a layer some scenes show, only while one of them is up: the next to take
            # over tells the math again.
            def emit_see_through_amount_while_up
              past = fresh("see_through_away")
              up = fresh("see_through_up")
              @see_through_scenes.each do |number|
                other = fresh("see_through_not_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
                @asm.brl(up)
                @asm.label(other)
              end
              @asm.brl(past)
              @asm.label(up)
              runtime_call("rt_see_through_math", [see_through_math_now])
              @asm.label(past)
            end

            # The sprites' bit of the colour math's registers (TS, CGADSUB).
            SPRITES_BIT = 0x10

            # The names of the sprites in the see-through layer, drawn from the palettes the
            # colour math reaches (Art#split_sprite_palettes!).
            def see_through_sprites = @see_through_sprites || []

            HALF = [SeeThrough::STEPS / 2, SeeThrough::STEPS / 2].freeze

            # The amounts of the game's see-through layer, asked before the kinds a Super Nintendo
            # cannot do (Lowering#refuse_what_snes_lacks!), so the framework's step that tells the
            # console an amount again (`:see_through`, put in for an amount worked out as the game
            # runs, or for more than one see-through layer) is refused in words about the amount.
            def refuse_see_through_amounts!
              layers = SeeThrough.layers(@program)
              return if layers.empty?

              refuse_unmade!("more than one see-through layer") if layers.length > 1
              refuse_see_through_amount!(layers.first)
            end

            def refuse_see_through_amount!(layer)
              return if added_to_what_is_behind?(layer)

              worked_out = [layer.shows, layer.behind].any? { |amount| amount.kind != :int }
              raise LoweringError, SEE_THROUGH_WORKED_OUT if worked_out
              return if SeeThrough.weights(layer, layer.shows.value, layer.behind.value) == HALF

              said = layer.split ? "`transparency: #{layer.behind.value}`" : "`shows: #{layer.shows.value}, shows_behind: #{layer.behind.value}`"
              raise LoweringError, "Layer :#{layer.name} is see-through by #{said}. A Super Nintendo can show a layer " \
                                   "half see-through only: `transparency:` from 50 to 56, or `shows: 50, shows_behind: " \
                                   "50`. It can also add a layer to what is behind it: `shows: 100, shows_behind: 100`. " \
                                   "To fix this, use one of those amounts for the Super Nintendo, for example " \
                                   "`transparency: console.mixes_by_half ? 50 : 40`."
            end

            SEE_THROUGH_WORKED_OUT = "This game works out how see-through a layer is as the game runs. A Super " \
                                     "Nintendo can show a layer half see-through only, so the amount must be a " \
                                     "number. To fix this, give the layer a number for the Super Nintendo, for " \
                                     "example `transparency: console.mixes_by_half ? 50 : 100 - mist`."

            def see_through_uncovered_message(layer)
              "Layer :#{layer.name} is see-through, and no background behind it covers the whole screen. Where " \
                "nothing is behind it, a Super Nintendo shows the layer whole, not half see-through. To fix this, " \
                "put a background behind layer :#{layer.name} that fills every cell of its map with tiles that " \
                "have no see-through pixels."
            end

            # Whether every map of +bg+ fills the console's whole grid of cells, each a tile with no
            # see-through pixel, so whatever its scroll it covers every pixel of the screen.
            def covers_screen?(bg)
              bg.every_map.all? do |map|
                columns, rows = TileMap.grid(map)
                map.length == rows && map.all? do |row|
                  Array(row).length == columns && Array(row).all? { |tile| solid_tile?(bg, tile) }
                end
              end
            end

            def solid_tile?(bg, tile)
              return false if tile.nil? || tile.negative?
              # A tile the game paints as it runs is never known solid.
              return false if @tile_runs.any? { |run| !run.picture && run.tiles.include?(bg.tiles.fetch(tile)) }

              image = Assets::Image.of(picture_named(bg.tiles.fetch(tile)))
              (0...64).none? { |at| image.tile_see_through_at?(at) }
            end

            # --- a background bent row by row ---

            # Reference#exec_scroll_rows: a standing declaration, gathered up front (#bends). Its rows
            # are worked out at every frame boundary (#emit_bends), not where it is written.
            def emit_scroll_rows(_node) = nil

            # The game's bends: the last each background is given, in the order the backgrounds were
            # first bent (Reference#collect_definitions).
            def bends
              @bends ||= @program.walk.select { |node| node.kind == :scroll_rows }.group_by(&:name).map { |_, said| said.last }
            end

            # Reference#work_out_bends, before the pass's wait: each row of the screen, its number
            # in the bend's variable, the bend's own steps, and how far along the row sits kept in the
            # layer's rows (Runtime::Picture.bend_offsets) for the frame the wait shows; the first row of each
            # bend, then the rest of each, leaving each variable at the screen's height.
            #
            # A game all of whose bends say a thing about whole bands of rows has each band worked
            # out once (RowBands). All of them or none: a block asked every row can change a number
            # another block reads, and then that one's rows are not bands at all.
            #
            # A BEND WHOSE SCENE IS AWAY is asked as it is on the interpreter if its block can change
            # a number the game reads (#bend_block_observable?), and otherwise takes none of the frame.
            # Only the rows of one whose scene is up are kept: a layer has one set of rows, and
            # another scene's bend may share the layer.
            def emit_bends
              bands = bend_bands
              height = Runtime::Picture::SCREEN_HEIGHT
              if bends_by_bands?
                bends.zip(bands).each { |bend, firsts| emit_bend_rows_unless_away(bend, height) { emit_bend_steps(bend, firsts) } }
              elsif bands.all?
                bends.zip(bands).each { |bend, firsts| emit_bend_rows_unless_away(bend, height) { emit_bend_bands(bend, firsts) } }
              else
                bends.each { |bend| emit_bend_rows_unless_away(bend, 1) { emit_bend_rows(bend, 0...1) } }
                bends.each { |bend| emit_bend_rows_unless_away(bend, height) { emit_bend_rows(bend, 1...height) } }
              end
            end

            # Each bend's bands, as the first row of each, or nil for a bend asked every row.
            def bend_bands
              @bend_bands ||= bends.map { |bend| RowBands.firsts(bend, Runtime::Picture::SCREEN_HEIGHT) }
            end

            # Each band of +firsts+ as the lines of its steps. A step counts so many lines at most.
            def band_steps(firsts)
              firsts.zip(firsts.drop(1) + [Runtime::Picture::SCREEN_HEIGHT]).map do |first, past|
                whole, rest = (past - first).divmod(Runtime::Picture::MOST_STEP_LINES)
                Array.new(whole, Runtime::Picture::MOST_STEP_LINES) + (rest.zero? ? [] : [rest])
              end
            end

            # Each band of +bend+ from its first row, kept as its steps, and lines of nought after.
            def emit_bend_steps(bend, firsts)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend)))]
              at = offsets
              firsts.zip(band_steps(firsts)).each do |first, steps|
                statement(Build.set(bend.row, first))
                bend.children.each { |child| statement(child) }
                value(bend.offset)
                from = at
                emit_row_store_while_up(bend) { emit_stores_of_steps(steps, from) }
                at += steps.length * Runtime::Picture::BAND_STEP_BYTES
              end
              statement(Build.set(bend.row, Runtime::Picture::SCREEN_HEIGHT))
              emit_row_store_while_up(bend) do
                @asm.ldx(0)
                @asm.lda(0)
                @asm.sta(@asm.long_x(at))
              end
            end

            # The steps of +lines+, each holding the offset in R0, from +at+.
            def emit_stores_of_steps(lines, at)
              @asm.ldx(0)
              lines.each_with_index do |count, step|
                place = at + (step * Runtime::Picture::BAND_STEP_BYTES)
                @asm.lda(count)
                @asm.sta(@asm.long_x(place))
                @asm.lda(@asm.direct(R0))
                @asm.sta(@asm.long_x(place + 2))
              end
            end

            # Each band of +bend+ from its first row, whose answer goes in all the band's rows.
            def emit_bend_bands(bend, firsts)
              height = Runtime::Picture::SCREEN_HEIGHT
              firsts.zip(firsts.drop(1) + [height]).each do |first, past|
                statement(Build.set(bend.row, first))
                bend.children.each { |child| statement(child) }
                emit_band_offset(bend, first...past)
              end
              statement(Build.set(bend.row, height))
            end

            def emit_band_offset(bend, rows)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend)))]
              value(bend.offset)
              emit_row_store_while_up(bend) do
                @asm.lda(@asm.direct(R0))
                @asm.ldx(rows.begin * 2)
                top = fresh("bend_band")
                @asm.label(top)
                @asm.sta(@asm.long_x(offsets))
                @asm.inx
                @asm.inx
                @asm.cpx(rows.end * 2)
                @asm.bne(top)
              end
            end

            # The block's code runs only while a scene showing +bend+'s background is up; every
            # screen's background is always up. The test leaves R0 alone, which the block reads.
            def emit_while_bend_up(bend, &block)
              scenes = scenes_showing(bend)
              return yield if scenes.nil?

              up = fresh("bend_up")
              past = fresh("bend_not_up")
              scenes.each do |number|
                @asm.lda(@asm.abs(place_of(@scene)))
                @asm.cmp(number)
                @asm.beq(up)
              end
              @asm.brl(past)
              @asm.label(up)
              yield
              @asm.label(past)
            end

            # The numbers of the scenes that put up +bend+'s background, or nil for one every screen
            # shows.
            def scenes_showing(bend)
              bg = background_declared_for(bend)
              return nil if scenery_holds?(@handover.always_up.scenery, bg)

              @scenes.filter_map { |scene, number| number if scenery_holds?(@handover.arrival(scene).scenery, bg) }
            end

            def scenery_holds?(scenery, bg) = scenery.any? { |up| up.equal?(bg) }

            # Whether the game can tell +bend+'s block ran. A block with no statements changes nothing,
            # unless it reads a list, whose index can stop the game.
            def bend_block_observable?(bend)
              !bend.children.empty? || bend.offset.walk.any? { |node| node.kind == :list_get }
            end

            # The block's rows, left out while the bend's scene is away if the game cannot tell. The
            # row's variable still ends at +last_row+, as the rows would have left it.
            def emit_bend_rows_unless_away(bend, last_row, &rows)
              return yield if scenes_showing(bend).nil? || bend_block_observable?(bend)

              emit_while_bend_up(bend, &rows)
              statement(Build.set(bend.row, last_row))
            end

            # Keeps a row's offset only while the bend's scene is up, in a bend whose block ran
            # whichever scene is up. One left out while away (#emit_bend_rows_unless_away) has no need.
            def emit_row_store_while_up(bend, &store)
              bend_block_observable?(bend) ? emit_while_bend_up(bend, &store) : yield
            end

            # Rows +rows+ (a range short of its end) of +bend+.
            def emit_bend_rows(bend, rows)
              top = fresh("bend_row")
              done = fresh("bend_rows_done")
              statement(Build.set(bend.row, rows.begin))
              @asm.label(top)
              bend.children.each { |child| statement(child) }
              emit_bend_offset(bend)
              statement(Build.add(bend.row, 1))
              return if rows.size == 1

              jump_unless(Build.binop(:<, Build.var_ref(bend.row), Build.int(rows.end)), done)
              @asm.brl(top)
              @asm.label(done)
            end

            # The row in the bend's variable kept at its place in the layer's rows: the low 16 bits of
            # how far along, all the console's scroll register takes.
            def emit_bend_offset(bend)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend)))]
              value(bend.row)
              @asm.lda(@asm.direct(R0))
              @asm.asl
              @asm.pha
              value(bend.offset)
              @asm.plx
              emit_row_store_while_up(bend) do
                @asm.lda(@asm.direct(R0))
                @asm.sta(@asm.long_x(offsets))
              end
            end

            # The bends a layer's line table cannot show yet: one on a status bar, or in a game that
            # never waits for the screen (whose rows the interpreter works out as it paints them).
            def refuse_unmade_bends!
              return if bends.empty?

              refuse_unmade!("a background bent row by row in a game that never waits for the screen") unless
                @program.walk.any? { |node| node.kind == :wait_vblank }
              refuse_unmade!("a status bar bent row by row") if bends.any? { |bend| background_declared_for(bend)&.bar? }
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays
            # where it was.
            def emit_show_map(node) = for_background(node) { |bg| emit_show_map_on(node, bg) }

            def emit_show_map_on(node, bg)
              which = keep_local(:map)
              value(node.which)
              store(which)
              done = fresh("map_shown")
              bg.every_map.each_index do |number|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(number)), other)
                runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, number).number), Build.int(0)])
                @asm.brl(done)
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
              store_number(place_of(hidden), 0)
              @asm.brl(done)
              @asm.label(placing)
              objects = node.names.map { |name| object_named(name) }
              if objects.any?(&:layer_pick)
                emit_layer_changing_sprites(node, objects)
              else
                present_items(node).each do |item|
                  next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                  emit_sprite_placing(object_named(item), item)
                end
              end
              @asm.label(done)
            end

            def object_named(name) = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }

            # One sprite placed, if it is showing, as deep as the name +at+ — its own, or one of the other
            # layers it can be put in (Stacking.choice_name) — has it among the backgrounds.
            def emit_sprite_placing(obj, at = obj.name)
              skip = fresh("sprite_off")
              jump_unless(Build.binop(:==, obj.active, Build.int(1)), skip)
              behind = sprite_depths.empty? ? [] : [Build.int((3 - sprite_depths.fetch(at, 3)) << SPRITE_PRIORITY_SHIFT)]
              emit_sprite_place(obj, obj.name, behind)
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
            # the sprite it names — back-most first, as every sprite here is. A sprite's placing is a
            # routine of its own (#sprite_placing_sections), so the entries share it. +depths+ is the
            # names of the depth being placed, by sprite, for a frame with sprites that change layer;
            # a sprite not named has no place at that depth.
            def emit_ordered_run(run, depths = nil)
              entry = keep_local(:ordered_entry)
              run.objects.each_index do |k|
                statement(Build.set(entry, Build.list_get(run.order, Build.int(k))))
                past = fresh("past_the_ordered")
                run.objects.each_with_index do |name, at|
                  next if depths && !depths.key?(name)

                  other = fresh("not_sprite")
                  jump_unless(Build.binop(:==, Build.var_ref(entry), Build.int(at)), other)
                  call_routine(sprite_placing_label(name, depths&.fetch(name)))
                  @asm.brl(past)
                  @asm.label(other)
                end
                @asm.label(past)
              end
            end

            # The routine placing sprite +name+, or placing it when it is at the depth called +at+.
            def sprite_placing_label(name, at = nil)
              (@sprite_placings ||= {})[[name, at]] ||= "sprite placing #{@sprite_placings.length}"
            end

            # The routine each sprite of an ordered run is placed by (#emit_ordered_run), made once the
            # game's routines are.
            def sprite_placing_sections
              (@sprite_placings || {}).map do |(name, at), label|
                routine_section(label, [], routine: "placing the sprite #{name.inspect}") do
                  next emit_sprite_placing(object_named(name)) unless at

                  emit_sprite_placed_at(object_named(name), at, Stacking.picture(@program).depths)
                end
              end
            end

            # A FRAME WITH SPRITES THAT CHANGE LAYER as the game runs (`put_in_layer`,
            # Reference#object_level): every depth any of them can be at, back-most first, and at each,
            # every sprite that can be there, placed when the layer it is in now is that one — so a
            # sprite is placed once, among the sprites of its layer now, behind the backgrounds as
            # that layer is. A run the game orders is walked at each depth, for those of its sprites
            # that are there, so the order holds inside each layer.
            def emit_layer_changing_sprites(node, objects)
              depths = Stacking.picture(@program).depths
              depth_of = ->(obj, level) { depth_names(obj).find { |name| depths[name] == level } }
              objects.flat_map { |obj| Stacking.levels_of(depths, obj) }.uniq.sort.each do |level|
                present_items(node).each do |item|
                  if item.is_a?(Build::DrawOrder)
                    here = item.objects.to_h { |name| [name, depth_of.call(object_named(name), level)] }.compact
                    emit_ordered_run(item, here) unless here.empty?
                  elsif (at = depth_of.call(object_named(item), level))
                    emit_sprite_placed_at(object_named(item), at, depths)
                  end
                end
              end
            end

            # +obj+ placed, if the depth called +at+ is where it is now.
            def emit_sprite_placed_at(obj, at, depths)
              there = at_level(obj, depths[at], depths)
              return emit_sprite_placing(obj, at) if there == true

              elsewhere = fresh("sprite_elsewhere")
              jump_unless(there, elsewhere)
              emit_sprite_placing(obj, at)
              @asm.label(elsewhere)
            end

            # The names +obj+ has a depth by: its own, and one for each other layer it can be put in.
            def depth_names(obj) = [obj.name, *Stacking.layer_choices(obj).map(&:name)]

            # When a sprite is at depth +level+: always (true), or a test of the number that picks its
            # layer — one naming a layer at that depth, or, for its own layer's depth, one naming none
            # of them (Reference#object_level).
            def at_level(obj, level, depths)
              own = depths[obj.name] == level
              layers = Array(obj.layers)
              return true if layers.empty?

              pick = Build.var_ref(obj.layer_pick)
              tests = layers.each_index.select { |i| depths[Stacking.choice_name(obj, layers[i])] == level }
                            .map { |i| Build.binop(:==, pick, Build.int(i)) }
              if own
                tests << Build.binop(:or, Build.binop(:<, pick, Build.int(0)), Build.binop(:>=, pick, Build.int(layers.length)))
              end
              tests.reduce { |either, test| Build.binop(:or, either, test) }
            end

            # The table of a sprite's pictures: how many, then each one's number.
            # +swapped+ for the table of the sprite's pictures drawn with that list of colours.
            def pose_table(obj, swapped = nil) = @pose_tables[[obj, swapped]] ||= "poses #{@pose_tables.length}"

            # The sprite drawn from the table its list of colours picks (Reference#object_recolor): a
            # number naming none of its lists draws its own colours.
            def emit_sprite_place(obj, name, behind)
              place = lambda do |swapped|
                runtime_call("rt_sprite_place", [LongAddress.new(pose_table(obj, swapped)), obj.pose, obj.x, obj.y,
                                                 Build.int(@sprite_names.name_number(obj.declared)), *behind])
              end
              return place.call(nil) if obj.recolors.empty?

              placed = fresh("sprite_colored")
              obj.recolors.each_with_index do |list, which|
                other = fresh("sprite_not_colored")
                jump_unless(Build.binop(:==, obj.recolor, Build.int(which)), other)
                place.call(list.is_a?(Symbol) ? color_list_named(list).colors : list)
                @asm.brl(placed)
                @asm.label(other)
              end
              place.call(nil)
              @asm.label(placed)
            end

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = store_number(place_of(sprites_hidden_flag), 1)

            # --- fades and tints ---

            # Reference#exec_fade, as a fade that walks the colours (IR::Fading walks every fade on a
            # console that cannot blend, Runtime::Tint): toward black or white by the 256ths
            # the amount comes to. A fade placed under a layer or held to part of the screen needs a
            # blend the build does not make.
            def emit_fade(node)
              refuse_unmade!("a fade held to part of the screen (`#{node.reaches}:`)") if node.reaches
              refuse_unmade!("a fade under a layer (`under:`)") if node.under
              toward = node.toward == :white ? Runtime::Tint::TOWARD_WHITE : Runtime::Tint::TOWARD_BLACK
              runtime_call("rt_tint", [Build.int(toward), Build.int(0), walk_steps(node)])
            end

            # Reference#exec_tint: toward the colour, in 256ths.
            def emit_tint(node)
              runtime_call("rt_tint", [Build.int(Runtime::Tint::TOWARD_COLOR), Build.int(Graphics::Color.resolve(node.color)),
                                       walk_steps(node)])
            end

            # FadeSteps' steps for a fade that walks the colours, worked out as the game runs;
            # Runtime::Tint holds them to 0..32.
            def walk_steps(node) = FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: true)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
