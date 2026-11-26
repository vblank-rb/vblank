# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # The picture, lowered for a Super Nintendo: the statements that draw, as calls into
          # Runtime::Picture, and the game's pictures made into tiles, palettes and maps (SNES::Art)
          # while the program is built.
          #
          # A tiled screen. Each background the game declares is given one of the console's two
          # layers of sixteen-colour tiles, the one declared last in front (BG1), as the interpreter
          # paints the one declared last over the rest. Each map it can show is made into a grid of
          # 32 or 64 cells each way (IR::TileMap), kept whole in the cartridge and copied onto its
          # layer when it is put up. A status bar or a background held above a row shown beside two
          # backgrounds, or a status bar beside a sprite behind a background, goes on the third
          # layer, of four-colour tiles (#make_third_layer_art). Each sprite is made of the console's 8×8 sprite pieces, placed
          # in the sprite table every pass the game places its sprites.
          module Picture
            STATEMENT_KINDS = %i[
              screen background scroll_background set_tile set_tile_block show_map present_objects hide_sprites fade tint
              place_bar scroll_rows copy_tiles copy_owed_tiles background_colors color_list_holds see_through
              pixelate box_background
            ].freeze

            def emit_picture_statement(node)
              case node.kind
              when :screen then emit_screen(node)
              when :background then emit_background(node)
              when :scroll_background then emit_scroll_background(node)
              when :set_tile then emit_set_tile(node)
              when :set_tile_block then emit_set_tile_block(node)
              when :show_map then emit_show_map(node)
              when :present_objects then emit_present_objects(node)
              when :hide_sprites then emit_hide_sprites(node)
              when :fade then emit_fade(node)
              when :tint then emit_tint(node)
              when :place_bar then emit_place_bar(node)
              when :scroll_rows then emit_scroll_rows(node)
              when :copy_tiles then emit_copy_tiles(node)
              when :copy_owed_tiles then emit_copy_owed_tiles(node)
              when :background_colors then emit_background_colors(node)
              when :color_list_holds then emit_color_list_holds(node)
              when :see_through then emit_see_through_amount(node)
              when :pixelate then emit_pixelate(node)
              when :box_background then emit_box_background(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether +program+ has a status bar, which the runtime then carries what places
            # (Runtime::Picture's rt_bar_place).
            def self.status_bar?(program) = program.walk.any? { |node| node.kind == :background && node.bar? }

            # WHETHER +program+ PUTS A BACKGROUND HELD TO SOME ROWS ON THE THIRD LAYER (Nodes::Background#held_to_rows?:
            # a status bar, or a background held above a row, which the line table switches,
            # Runtime::Picture's BAR_TABLE): some screen shows it beside two other
            # backgrounds. Mode 1 has two layers of sixteen-colour tiles and a third of four, and the
            # held background is the one that goes there: it is what Super Bomberman puts there (its
            # stages show an arena on the two, each at its own scroll, and the bar on the third, which
            # its line interrupt switches on above line 32), and a bar of numbers and icons is the
            # picture that fits four colours. A game whose screens show it beside one background at
            # most keeps it on one of the two, as before, and builds the same bytes.
            #
            # Or some screen shows a status bar beside a sprite the stack puts behind a background. The
            # interpreter draws no background under the bar, so there the sprite shows over the bar
            # while the background hides it above the bar's top. A sprite's priority puts it behind a
            # layer on every row, the bar's too; but the third layer, kept low, is behind every
            # sprite whatever its priority, and the bar's rows show no other layer
            # (Runtime::Picture's line table), so there the two agree.
            def self.third_layer?(program)
              return false if Lowering::Paint.painted?(program)

              Stacking.screenfuls(program).any? do |screenful|
                scenery = screenful.scenery
                (scenery.any?(&:held_to_rows?) && scenery.length > BACKGROUND_LAYERS) ||
                  (scenery.any?(&:bar?) &&
                   Stacking.scenery_over_objects?(screenful.depths, scenery: scenery, objects: screenful.objects))
              end
            end

            # Whether +program+ holds a background above a row, which takes the bar's line table.
            def self.background_rows_held?(program) = program.walk.any? { |node| node.kind == :background && node.above_row }

            # Whether the line table reads, as it is made, how alone the background held now is
            # (Runtime::Picture's ROW_HELD_ALONE, Nodes::Background#shown_above_row): in a game that shows one alone
            # above its row (`alone: true`) on one of the two ordinary layers, or one without sprites
            # (`alone: :without_sprites`) on any layer. One on the third layer shows alone with the
            # sprites whatever it sets (#refuse_held_see_through!), so `alone: true` there needs
            # nothing more.
            def self.alone_flag_in_line_table?(program)
              held_hides_sprites?(program) ||
                (program.walk.any? { |node| node.kind == :background && node.alone } && !third_layer?(program))
            end

            # Whether +program+ shows a background alone without sprites (`alone: :without_sprites`),
            # which the line table then leaves the sprites out above the row for.
            def self.held_hides_sprites?(program) = program.walk.any? { |node| node.kind == :background && node.hides_sprites }

            # Whether +program+ changes colours as it runs, which the runtime then keeps a place for
            # (Runtime::Tint's rt_colors_hold).
            def self.changing_colors?(program) = program.walk.any? { |node| %i[background_colors color_list_holds].include?(node.kind) }

            # Does the game fade to black, which the display's brightness does (Runtime::Tint)?
            def self.fades_to_black?(program) = program.walk.any? { |node| node.kind == :fade && node.toward != :white }

            # Whether a background a scene puts up is bent, whose rows then go straight while that
            # scene is away (Runtime::Picture::LAYERS_STRAIGHT). +row_bends+ is the game's bends
            # (LoweringPlan#row_bends).
            def self.scene_bends?(row_bends, handover)
              always = handover.always_up.scenery.map(&:name)
              row_bends.bends.any? { |bend| !always.include?(bend.background) }
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

            # The runs whose pictures are held in the cartridge (`tile_pictures`), as each run's number
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

            # What the build can know about the table of 128 rows. A sprite past the last row is not
            # drawn, with no error from the console, and only here is it known how many rows each
            # picture came to. A pool's sprites and letters of text are left out of the count: how
            # many show at once is decided as the game runs, so this counts what is certain, the
            # sprites a screen declares, each at its largest pose.
            #
            # No row is a sprite's own here. The runtime hands the rows out on every pass, one for
            # each piece of each sprite that shows, as rt_sprite_place places it (Runtime::Picture,
            # "SPRITES"), so the table holds what is up on that pass and nothing else: a hidden
            # sprite, or one of a scene that is not up, takes no row, ordered or not. So the count
            # is of the sprites that can be up together (SpriteRows.screens_shown_together), never
            # the layout SpriteRows.plan makes for a console that settles each sprite's rows as the
            # game is built, where a sprite drawn in an order keeps rows on every screen. It is
            # still the most a screen can hold, not what any one pass holds: the build cannot tell
            # a walking sprite the game hides before it shows a dying one from two that show
            # together. So the warning says it is that bound and names what it added.
            def sprite_table_findings
              return [] if painted?

              screens = IR::SpriteRows.screens_shown_together(@program) { |node| rows_of_declared_sprite(node) }
              screen = screens.max_by(&:count)
              return [] if screen.nil? || screen.count <= Runtime::Picture::MOST_SPRITES

              [Guardrails::Finding.new(check: :snes_sprite_table, severity: :warning, node: :program,
                                       message: sprite_table_message(screen))]
            end

            def sprite_table_message(screen)
              where = screen.scenes.empty? ? "one screen" : "the scene #{scenes_named(screen.scenes)}"
              "The sprites of #{where} can take #{screen.count} rows of the sprite table. A Super Nintendo has " \
                "#{Runtime::Picture::MOST_SPRITES}. A sprite past the last row is not drawn. Each piece of a " \
                "picture takes one row. This count adds every sprite on the screen at its biggest picture, shown " \
                "or hidden: #{counted_sprites_named(screen)}. If some of these sprites never show at the same " \
                "time, the screen can fit. To fix this, use fewer sprites, or make their pictures of fewer pieces."
            end

            def scenes_named(scenes) = scenes.map { |scene| ":#{Modes.strip_scene_prefix(scene)}" }.join(" and ")

            # The sprites a count added, by their biggest picture, the most rows first, in the
            # author's names (a sprite's own name is the framework's): ":banner (50 rows) 2 times".
            def counted_sprites_named(screen)
              nodes = IR::Stacking.objects_in_draw_order(@program).to_h { |node| [node.name, node] }
              biggest = screen.names.filter_map do |name|
                next if rows_of_declared_sprite(nodes.fetch(name)).zero?

                @objects.fetch(name).poses.map { |pose| [pose, @art.sprite_pictures.fetch(pose).pieces.length] }.max_by(&:last)
              end
              biggest.tally.sort_by { |(_pose, rows), times| -rows * times }
                     .map { |(pose, rows), times| ":#{pose} (#{rows} #{rows == 1 ? 'row' : 'rows'})#{" #{times} times" if times > 1}" }
                     .join(", ")
            end

            # What a crowded scene gave up to fit its sprites (Art, "A crowded screen's sprites"): the
            # pictures drawn in pieces of 8×8 where a square would take more tiles, and a scene
            # drawn in pieces of 8×8 alone. Each piece is a row the runtime places on every frame, so
            # a frame that was in time can run late, and the author is told which pictures and how
            # many rows.
            def crowded_scene_findings
              lean = @art.lost_squares.map do |scene, pictures|
                Guardrails::Finding.new(check: :snes_crowded_scene_squares, severity: :warning, node: :program,
                                        message: lost_squares_message(scene, pictures))
              end
              lean + @small_sprite_scenes.map do |scene|
                Guardrails::Finding.new(check: :snes_crowded_scene_small_pieces, severity: :warning, node: :program,
                                        message: small_scene_message(scene))
              end
            end

            # The pieces each sprite picture was made of (Art#sprite_pictures), as the interpreter and
            # the runtimes count them on a line and in the table (SpriteLines.pieces_built): by
            # [picture's name, the colours a copy drawn with other colours is drawn in, or nil], each
            # piece's [across, down, width, height] with the one in front first. The art lists a
            # picture's pieces in the order they go into the table, which is back-most first
            # (#emit_present_objects), so they are turned round.
            public def sprite_pieces_built
              @art.sprite_pictures.to_h do |key, picture|
                places = picture.pieces.reverse.map do |piece|
                  side = piece.big ? SpritePieces::BIG : SpritePieces::SIZE
                  [piece.dx, piece.dy, side, side]
                end
                [key.is_a?(Array) ? key : [key, nil], places]
              end
            end

            # How many sprite tiles +scene+ leaves free (Art#free_sprite_tiles), for SNES#build.
            def free_sprite_tiles(scene) = @art.free_sprite_tiles(scene)

            # Stops the try where a screen's sprites did not fit, once every screen is made
            # (Art#refuse_crowded_scenes!), for SNES#build.
            public def refuse_crowded_scenes! = @art&.refuse_crowded_scenes!

            # Pictures named in a warning before the rest are counted.
            PICTURES_NAMED = 3

            def lost_squares_message(scene, pictures)
              names = pictures.keys.map { |name| ":#{Array(name).first}" }
              named = names.first(PICTURES_NAMED).join(", ")
              named += " and #{names.length - PICTURES_NAMED} more" if names.length > PICTURES_NAMED
              "The sprites of the scene :#{Modes.strip_scene_prefix(scene)} do not all fit in video memory as squares " \
                "of 16×16. #{names.length} pictures are drawn in pieces of 8×8 where a square takes more tiles: #{named}. " \
                "When one of each shows, they take #{pictures.values.sum} more rows of the sprite table. The console " \
                "places each row again on every frame, so each frame takes more time. To keep the squares, use fewer " \
                "different pictures in this scene."
            end

            def small_scene_message(scene)
              "The sprites of the scene :#{Modes.strip_scene_prefix(scene)} do not fit in video memory as squares of " \
                "16×16. All of its pictures are drawn in pieces of 8×8. Each sprite takes more rows of the sprite " \
                "table. The console places each row again on every frame, so each frame takes more time. To keep " \
                "the squares, use fewer different pictures in this scene."
            end

            def rows_of_declared_sprite(node)
              return 0 if node.declared.nil? || Guardrails::SpriteWords.pool?(node)

              @objects.fetch(node.name).poses.map { |pose| @art.sprite_pictures.fetch(pose).pieces.length }.max.to_i
            end

            def prepare_picture
              refuse_backdrops_of_its_own!
              @third_layer = Picture.third_layer?(@program)
              @alone_flag_in_line_table = Picture.alone_flag_in_line_table?(@program)
              over_picture = Lowering::Paint.sprites_over_picture?(@program)
              @art = Art.new(backdrop: @cache.handover.game_backdrop, sprite_squares: @sprite_squares && !over_picture,
                             painted_screen_room: over_picture,
                             screen_colors: @screen_colors, sprite_colors: @sprite_colors, scene_tiles: @sprite_tiles,
                             background_tiles: @scene_background_tiles, lean_square_scenes: @lean_square_scenes,
                             small_sprite_scenes: @small_sprite_scenes,
                             third_layer: @third_layer, shared_held_lists: @shared_held_lists, tile_memo: @tile_memo)
              sizes = @program.walk.select { |node| node.kind == :background }.map(&:tile_w).uniq
              @art.reserve_blank_big_tile if sizes.length > 1
              @pictures = by_kind(:bitmap)
              @objects = by_kind(:object)
              @backgrounds = by_kind(:background)
              @set_tiles_by_name = @program.walk.select { |node| node.kind == :set_tile }.group_by(&:name)
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
            # or a painted screen (Lowering::Paint) with nothing drawn from tiles over it but the
            # sprites a game shows over the picture (Runtime::Paint, "sprites over the picture").
            def refuse_unmade_picture!
              refuse_unmade!("a sprite's pose drawn from sprite tiles the game loads (`sprite_tiles`)") if @program.walk.any? { |node| node.kind == :tile_pose }
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              others = screens - %i[tiled bitmap]
              refuse_unmade!("a `screen :#{others.first}`") unless others.empty?
              refuse_unmade!("both a painted (bitmap) screen and a tiled one") if screens.include?(:tiled) && painted?
              if painted?
                refuse_unmade!("a background on a painted (bitmap) screen") unless @backgrounds.empty?
                refuse_unmade!("a hardware sprite on a painted (bitmap) screen") unless @objects.each_value.all?(&:over_picture)
                refuse_unmade_sprites_on_chip_paint!
              end
              refuse_unmade_doubled_screen! if doubled?
              # The windows hide a layer on the main screen alone (TMW); a see-through layer is mixed
              # from the sub screen, which this build does not hold to the box.
              if Picture.boxes?(@program) && !SeeThrough.layers(@program).empty?
                refuse_unmade!("a background held to a box (`show_only_inside`) beside a see-through layer")
              end
              @program.walk.select { |node| node.kind == :background }.each do |bg|
                unless bg.tile_w == bg.tile_h && [8, BIG_TILE].include?(bg.tile_w)
                  refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}")
                end
                refuse_unmade_walking!(bg) if bg.several_sets?
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
              end
            end

            # What a painted screen of big pixels (Runtime::PaintDoubled) does not paint yet: a Super
            # FX cartridge. The chip's plot writes the planar tiles of Paint's screen
            # (Runtime::ChipPaint, ChipFill, ChipBlit, ChipColumns), and every routine it runs
            # paints that layout; Mode 7's tiles are a byte a pixel, which plot has no mode for. The
            # chip could store bytes itself, but that is every chip routine written again.
            def refuse_unmade_doubled_screen!
              return unless @chip_board

              raise NotMadeYet.new(DOUBLED_ON_CHIP, part: "the picture")
            end

            # A sprite over a picture the Super FX paints: the chip's screen is switched off above and
            # below the picture's rows (Runtime::Letterbox), and the copy in the blank is laid out for
            # the chip's own copy of the screen. Neither is made to carry the sprite table yet.
            def refuse_unmade_sprites_on_chip_paint!
              return unless @chip_board && !@objects.empty?

              raise NotMadeYet.new(SPRITES_ON_CHIP_PAINT, part: "the picture")
            end

            SPRITES_ON_CHIP_PAINT = "This game shows a sprite over the picture (`over_picture: true`) on a Super FX " \
                                    "cartridge. The build does not make that yet. To fix this, build the game without " \
                                    "the Super FX, or paint the sprite into the picture (remove `over_picture: true`)."

            DOUBLED_ON_CHIP ="This game has big pixels (`pixel_size: 2`) on a Super FX cartridge. The Super FX chip " \
                              "paints its pixels in the tiles of a screen with small pixels. A screen with big pixels " \
                              "keeps one byte for each pixel, on the Super Nintendo's turning layer. The build does " \
                              "not make the chip paint that layout yet. To fix this, remove `pixel_size: 2`, or build " \
                              "the game without the Super FX."

            # Every picture a sprite can show, made into sprite pieces in the order SpriteNames numbers
            # them, a canvas's picture among them (#make_run_art), so the number a picture is made
            # with is the one a reader of the drawn sprites turns back into its name.
            #
            # The pictures of a see-through layer's sprites are drawn from the console's last four
            # sprite palettes, and every other picture from the first four (Art#split_sprite_palettes!),
            # so a picture both kinds of sprite show would need to be made twice, which is not made yet.
            def make_sprite_art
              @art.split_sprite_palettes!(unmixed_scenes: scenes_without_see_through) unless see_through_sprites.empty?
              @sprite_pictures = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              mixed = see_through_sprites.flat_map { |name| @objects.fetch(name).poses }.uniq
              solid = (@objects.values.reject { |obj| see_through_sprites.include?(obj.name) }.flat_map(&:poses) +
                       @tile_runs.filter_map(&:picture)).uniq
              refuse_unmade!("a picture shown both by a see-through sprite and by another") if mixed.intersect?(solid)

              painted = @tile_runs.filter_map(&:picture)
              reserve_shared_sprite_art(mixed, painted)
              reserve_list_places_palettes(mixed, painted)
              @sprite_pictures.each_with_index do |name, number|
                run = @tile_runs.index { |tile_run| tile_run.picture == name }
                if painted.include?(name)
                  make_run_art(run) unless @run_places[run]
                else
                  @art.sprite_picture(name, @cache.image(picture_named(name)), mixed: mixed.include?(name), number: number,
                                                                                  held: picture_palette_in_places(name, mixed.include?(name)),
                                                                                  scenes: colors_scenes_of_picture(name),
                                                                                  tile_scene: tiles_scene_of_picture(name))
                end
              end
              @tile_runs.each_with_index do |run, number|
                make_run_art(number) unless @run_places[number] || colors_scene_of_run(run) || tiles_scene_of_run(run)
              end
              make_recolored_art(mixed)
            end

            # The sprite art every screen keeps, in a game of a screen's own sprite colours or tiles: all
            # of it placed before any scene takes its copies (Art#sprite_palettes), as the backgrounds'
            # colours are (#make_shared_background_colors). Lists the game changes first, which want
            # a set each, and pictures painted from a list, which keep their tiles for good.
            #
            # A copy drawn with a list only some scenes keep a set for (#colors_scenes_of_list) is
            # placed last, since its set is taken in those scenes' copies. After it, each copy and then
            # each picture that only some scenes show (#colors_scenes_of_picture), whose colours take
            # a set in those scenes' copies alone (Art#sprite_palette_copies): the copies first, since
            # in a game of one set of pictures each wants a set to itself where a picture can share.
            # They go before any scene's own, so a set alike in all their scenes is still free.
            #
            # Must place everything else every screen keeps first: a scene's copy is taken the first
            # time it is asked for (Art#sprite_palettes).
            def reserve_shared_sprite_art(mixed, painted)
              return unless @sprite_colors || @sprite_tiles

              lists_of_some_scenes = []
              copies_of_some_scenes = []
              each_recolored_picture do |pose, list, swapped|
                next if scene_of_recolored(pose, list)

                # A list the game changes holds its set where it is drawn, whoever shows the copy. One
                # that can show its pose's tiles (#recolored_copy) places the pose's colours first, which
                # takes the copies of the pose's scenes, so it waits for what every screen keeps.
                if changing_list?(list) && (several_scenes?(colors_scenes_of_list(list)) || worn_tried?)
                  lists_of_some_scenes << [pose, list, swapped]
                elsif !changing_list?(list) && colors_scenes_of_recolored(pose, list)
                  copies_of_some_scenes << [pose, list, swapped]
                else
                  reserve_shared_recolored_picture(pose, list, swapped, mixed)
                end
              end
              @tile_runs.each_with_index { |run, number| make_run_art(number) if @sprite_pictures.include?(run.picture) }
              pictures_of_some_scenes = []
              @sprite_pictures.each do |name|
                next if painted.include?(name) || scene_of_picture(name)

                if colors_scenes_of_picture(name)
                  pictures_of_some_scenes << name
                else
                  reserve_shared_plain_picture(name, mixed)
                end
              end
              lists_of_some_scenes.each { |pose, list, swapped| reserve_shared_recolored_picture(pose, list, swapped, mixed) }
              copies_of_some_scenes.each { |pose, list, swapped| reserve_shared_recolored_picture(pose, list, swapped, mixed) }
              pictures_of_some_scenes.each { |name| reserve_shared_plain_picture(name, mixed) }
            end

            # The sets laid out as their lists' places that poses drawn with other lists take
            # (#picture_palette_in_places), before any picture is made: a picture made first would
            # start a set of its own colours, where it can find them in the pose's.
            def reserve_list_places_palettes(mixed, painted)
              return unless worn_tried?

              @sprite_pictures.each { |name| picture_palette_in_places(name, mixed.include?(name)) unless painted.include?(name) }
            end

            def reserve_shared_plain_picture(name, mixed)
              @art.reserve_shared_sprite_picture(@cache.image(picture_named(name)), mixed: mixed.include?(name),
                                                                                       held: picture_palette_in_places(name, mixed.include?(name)),
                                                                                       scenes: colors_scenes_of_picture(name))
            end

            def reserve_shared_recolored_picture(pose, list, swapped, mixed)
              with_recolored_copy(pose, list, swapped, mixed.include?(pose)) do |copy|
                @art.reserve_shared_sprite_picture(copy.image, mixed: mixed.include?(pose), held: copy.held, scenes: copy.scenes,
                                                               worn: copy.worn)
              end
            end

            # The block given the copy of +pose+ drawn with +list+ (#recolored_copy), and given it again
            # made pixel by pixel where it is its pose's tiles and its scenes have no set left for its
            # colours (Art#worn_picture, #sharing_or_nil).
            def with_recolored_copy(pose, list, swapped, mixed)
              copy = recolored_copy(pose, list, swapped, mixed)
              return yield(copy) unless copy.worn

              sharing_or_nil { yield(copy) } || yield(plain_recolored_copy(pose, list, swapped, mixed))
            end

            # How the copy of +pose+ drawn with +list+ (colours +swapped+) is made (#recolored_copy): from
            # +image+, with +held+ the set of a list kept in its places (#palette_of_worn_list), +scenes+
            # those whose colours +image+ is placed in (Art#sprite_picture), and +worn+ an Art::Worn for a
            # copy drawn from the pose's own tiles.
            RecoloredCopy = Data.define(:image, :held, :scenes, :worn)

            # The copy of +pose+ drawn with +list+. In a game of +shared_pose_tiles+ (and not of
            # +one_sprite_tile_set+), a pose that keeps its places is drawn in its list's places
            # (#picture_palette_in_places), so its copy is the same tiles in a set of the list's colours
            # in their places, whatever colours repeat, as the interpreter recolours it by place. A pose
            # of colours alone is its own picture in a set of the copy's colours, where each
            # colour the pose draws comes to one colour of the list in every set of colours it can hold
            # (Art#worn_for), placed as the pose places its own. Otherwise kept in places where the list
            # is (#palette_of_worn_list), or a copy made pixel by pixel (Assets::RecoloredImage), with
            # tiles of its own wherever its colours land in other places of its set.
            def recolored_copy(pose, list, swapped, mixed)
              image = @cache.image(picture_named(pose))
              copy_scenes = colors_scenes_of_recolored(pose, list)
              if worn_tried? && worn_by_place?(image) && picture_palette_in_places(pose, mixed)
                held = if changing_list?(list) then recolored_list_palette(list, mixed)
                       else sharing_or_nil { palette_in_places(places_shown(image, swapped), mixed, copy_scenes) }
                       end
                return held ? RecoloredCopy.new(image: image, held: held, scenes: copy_scenes, worn: nil) : plain_recolored_copy(pose, list, swapped, mixed)
              end

              worn = worn_of(pose, image, list, swapped) if worn_tried?
              return RecoloredCopy.new(image: image, held: nil, scenes: colors_scenes_of_picture(pose), worn: worn) if worn

              plain_recolored_copy(pose, list, swapped, mixed)
            end

            # The copy of +pose+ drawn with +list+ as it is made without +shared_pose_tiles+.
            def plain_recolored_copy(pose, list, swapped, mixed)
              image = @cache.image(picture_named(pose))
              copy_scenes = colors_scenes_of_recolored(pose, list)
              held = palette_of_worn_list(pose, list, swapped, mixed)
              return RecoloredCopy.new(image: image, held: held, scenes: copy_scenes, worn: nil) if held

              recolor = Assets::Recolor.of(image, swapped)
              RecoloredCopy.new(image: Assets::RecoloredImage.new(image: image, recolor: recolor), held: nil, scenes: copy_scenes, worn: nil)
            end

            # The colours a copy of +image+ in the list +swapped+ shows at each place, place 0 first: the
            # list's, and the picture's own past the list's end, as Assets::Recolor#color_at_place gives.
            def places_shown(image, swapped)
              recolor = Assets::Recolor.of(image, swapped)
              [swapped.first, *(1...[swapped.length, image.colors.length].max).map { |place| recolor.color_at_place(place, image.colors[place]) }]
            end

            # Whether a copy is tried as its pose's own tiles (#recolored_copy).
            def worn_tried? = @shared_pose_tiles && !@one_sprite_tile_set

            # The Art::Worn of +image+, the picture +pose+, drawn with +list+ (colours +swapped+), or nil where it
            # cannot show the pose's tiles. A list the game changes is worn in each set it can hold,
            # kept in the scenes that draw with it, as its own set is (#recolored_list_palette), since a
            # change of it writes that set's number whichever of them is up.
            def worn_of(pose, image, list, swapped)
              return @art.worn_for(image, [Assets::Recolor.of(image, swapped)], colors_scenes_of_recolored(pose, list)) unless changing_list?(list)

              named = color_list_named(list)
              recolors = [named.colors, *named.recolors].map { |colors| Assets::Recolor.of(image, colors) }
              @art.worn_for(image, recolors, colors_scenes_of_list(list), list: list)
            end

            # The one scene whose sprites alone show the picture +name+ (LoweringPlan#scene_showing_picture);
            # nil where every screen keeps it. Not a picture painted from a list, whose palette has its
            # colours in its places and whose tiles the game fills.
            def scene_of_picture(name)
              return nil unless @tile_runs.none? { |run| run.picture == name }

              @plan.scene_showing_picture(name)
            end

            def tiles_scene_of_picture(name) = @sprite_tiles ? scene_of_picture(name) : nil

            # The scenes whose sprites alone show the picture +name+, in a game of +sprite_colors+, in
            # the order the game numbers them, so that its colours hold a set in those scenes alone
            # (Art#sprite_palette_copies); nil where every screen keeps it, and in any other game.
            def colors_scenes_of_picture(name)
              return nil unless @sprite_colors && @tile_runs.none? { |run| run.picture == name }

              scenes_of(@objects.values.select { |obj| obj.poses.include?(name) })
            end

            # The same for the copy of the picture +pose+ drawn with +list+.
            def scene_of_recolored(pose, list) = one_scene_of(objects_wearing(pose, list))

            def colors_scenes_of_recolored(pose, list) = @sprite_colors ? scenes_of(objects_wearing(pose, list)) : nil
            def tiles_scene_of_recolored(pose, list) = @sprite_tiles ? scene_of_recolored(pose, list) : nil

            def objects_wearing(pose, list) = @objects.values.select { |obj| obj.poses.include?(pose) && obj.recolors.include?(list) }

            # The scenes of +objects+, in the order the game numbers them; nil where one of them is
            # every screen's, or there are none.
            def scenes_of(objects)
              scenes = objects.map(&:scene).uniq
              return nil if scenes.empty? || scenes.include?(nil)

              scenes.sort_by { |scene| @scenes.fetch(scene) }
            end

            # Whether some picture is shown only by the sprites of one scene, so that bringing each
            # scene's tiles in as it takes over can leave room (SNES#build).
            public def sprites_of_one_scene? = @sprite_pictures.any? { |name| scene_of_picture(name) }

            # The scenes whose sprites alone draw with +list+, a list of colours the game changes, so
            # that its set is kept in those scenes' colours alone: its one scene in a game of
            # +sprite_colors+, or several where that is :lists (Art#held_scene_sprite_palette). Nil
            # where a sprite every screen shows draws with it, and in any other game.
            def colors_scenes_of_list(list)
              return nil unless @sprite_colors

              scenes = scenes_drawing_with(list)
              scenes if scenes && (scenes.one? || @sprite_colors == :lists)
            end

            # The scenes of the sprites drawn with +list+, in the order the game numbers them; nil
            # where one of them is every screen's.
            def scenes_drawing_with(list) = scenes_of(@objects.values.select { |obj| obj.recolors.include?(list) })

            # Whether a list of sprite colours the game changes is drawn with by the sprites of
            # several scenes and none every screen shows, so that a build keeping its set in those
            # scenes alone can leave room (SNES#build).
            def sprite_lists_of_some_scenes?
              changing_sprite_lists.any? { |list| several_scenes?(scenes_drawing_with(list)) }
            end

            def changing_sprite_lists = @objects.values.flat_map(&:recolors).uniq.select { |list| changing_list?(list) }

            # Whether a sprite's +list+ is a list of colours the game changes (`recolor`).
            def changing_list?(list) = list.is_a?(Symbol) && !color_list_named(list).recolors.empty?

            # Whether +scenes+ (a list's, or nil) is more than one scene.
            def several_scenes?(scenes) = !scenes.nil? && scenes.length > 1

            def one_scene_of(objects)
              scenes = objects.map(&:scene).uniq
              scenes.first if scenes.one?
            end

            # A sprite drawn with other colours (`draw_with`): each of its lists made, ahead of time,
            # into a copy of each of its pictures (Assets::Recolor, the rule the interpreter draws
            # by), with tiles and a palette of its own — two places of a picture's list may share a
            # colour and still swap to two, so no one palette could stand in for another. A game of
            # +one_sprite_tile_set+ keeps those places instead (#palette_in_places), and a game of
            # +shared_pose_tiles+ draws a copy from its picture's own tiles where it can (#recolored_copy). They are
            # made after every plain picture, whose numbers stay SpriteNames'; #sprite_picture_names
            # names each copy as the picture it copies. A list's colours never change as the game
            # runs: a list told to hold others (`holds`) is not made yet.
            def make_recolored_art(mixed)
              each_recolored_picture do |pose, list, swapped|
                with_recolored_copy(pose, list, swapped, mixed.include?(pose)) do |copy|
                  @art.sprite_picture([pose, swapped], copy.image, mixed: mixed.include?(pose), held: copy.held, scenes: copy.scenes,
                                                                   worn: copy.worn, tile_scene: tiles_scene_of_recolored(pose, list))
                end
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

            # The palette the copy of +pose+ drawn with +list+ (colours +swapped+) keeps its colours in
            # place for place, whichever picture it copies: a list of sprite colours the game changes
            # (`recolor`), or any list in a game of +one_sprite_tile_set+. Nil for a copy with a
            # palette worked out from its own colours.
            def palette_of_worn_list(pose, list, swapped, mixed)
              return recolored_list_palette(list, mixed) if changing_list?(list)

              palette_in_places(swapped, mixed, colors_scenes_of_recolored(pose, list)) if @one_sprite_tile_set
            end

            # A sprite drawn with a list the game changes is one picture whatever the list holds.
            def recolored_list_palette(list, mixed)
              key = [:sprites, list]
              colors = palette_colors(color_list_named(list).colors)
              scenes = colors_scenes_of_list(list)
              held_palette_or_refuse do
                if several_scenes?(scenes)
                  @art.held_scene_sprite_palette(key, colors, scenes, mixed: mixed)
                else
                  @art.held_sprite_palette(key, colors, mixed: mixed, scene: scenes&.first)
                end
              end
            end

            # One set of a sprite's pictures for all its lists (+one_sprite_tile_set+, which SNES#build
            # turns on when the copies do not fit). Each sprite row names which set of colours it is
            # drawn from, so a tile that holds places rather than colours can be shown in any list: the
            # picture and every list it is drawn with each take a set whose colours stay in their own
            # places, and every copy comes to the same tiles. A set is then a whole list, and shared
            # only with a list of the same colours, which is why it is not how every game is built.
            # Where +scenes+ alone show it, the set is taken in theirs (Art#held_scene_sprite_palette).
            def palette_in_places(list, mixed, scenes)
              colors = palette_colors(list)
              key = [:places, colors, mixed, scenes]
              return @art.held_scene_sprite_palette(key, colors, scenes, mixed: mixed) if several_scenes?(scenes)

              @art.held_sprite_palette(key, colors, mixed: mixed, scene: scenes&.first)
            end

            def palette_colors(list) = list.drop(1).map { |color| color & 0x7FFF }

            # The palette the picture +name+ takes in such a game, or nil for a picture no sprite draws
            # with another list, which is made as ever.
            #
            # In a game of +shared_pose_tiles+, a picture that keeps its places takes a set laid out as its
            # list, which other pictures can still draw from (Art#list_places_palette), so its copies are
            # its own tiles (#recolored_copy).
            def picture_palette_in_places(name, mixed)
              return nil unless @objects.each_value.any? { |obj| !obj.recolors.empty? && obj.poses.include?(name) }

              image = @cache.image(picture_named(name))
              return palette_in_places(image.colors, mixed, colors_scenes_of_picture(name)) if @one_sprite_tile_set
              return nil unless worn_tried? && worn_by_place?(image)

              (@list_places_of ||= {}).fetch(name) do
                @list_places_of[name] = sharing_or_nil do
                  @art.list_places_palette(palette_colors(image.colors), colors_scenes_of_picture(name), mixed: mixed)
                end
              end
            end

            # The block's set, or nil where its scenes have no set left for it, so that the picture or
            # copy asking is made the way it is without +shared_pose_tiles+: a set for each list a pose is
            # worn in saves its tiles, but a screen with more lists than sets keeps them for the copies
            # it can. Sprite colours kept for the whole game are refused as ever, so the build tries each
            # screen's own first (SNES#settings_after).
            def sharing_or_nil
              yield
            rescue Art::TooManySpriteColors
              raise
            rescue Art::TooMuch
              nil
            end

            # Whether +image+'s copies in other lists are drawn by place, as the interpreter draws a picture
            # that keeps its places (Assets::Recolor#color_at_place).
            def worn_by_place?(image) = !image.places.nil?

            # Whether a sprite wears another list, so that its pictures can share tiles (SNES#build).
            public def sprites_draw_with_lists? = @objects.each_value.any? { |obj| !obj.recolors.empty? }

            # Reference#exec_color_list_holds: the sets the list can hold, written over its palette and
            # over each set showing a copy of a pose in it (Art#worn_list_palettes). A list nothing is
            # drawn with has no palette, and nothing to show.
            #
            # A list some scenes keep to themselves has a palette only while one of those scenes is
            # up, and another scene's colours in it otherwise: the number is kept, and set again as
            # one of them arrives (#emit_scene_colors), so it writes only with one of them up.
            def emit_color_list_holds(node)
              emit_backdrop_follows(node)
              return unless @art.held_palette_of([:sprites, node.name]) || @art.worn_list_palettes(node.name).any?

              choice = @sprite_color_choices[node.name]
              return emit_sprite_list_write(node.name, node.which) unless choice

              statement(Build.set(choice, node.which))
              other = fresh("not_scene")
              jump_unless(scene_up_test(colors_scenes_of_list(node.name)), other)
              emit_sprite_list_write(node.name, Build.var_ref(choice))
              @asm.label(other)
            end

            # A test that one of +scenes+ is up.
            def scene_up_test(scenes)
              scenes.map { |scene| Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(scene))) }
                    .reduce { |either, test| Build.binop(:or, either, test) }
            end

            # The write of set +which+ of the list +name+: into its own palette, where a copy is drawn from
            # it place for place, and into each palette showing a pose's tiles in it, in that pose's places.
            def emit_sprite_list_write(name, which)
              palette = @art.held_palette_of([:sprites, name])
              list = color_list_named(name)
              worn = @art.worn_list_palettes(name)
              sets = [list.colors, *list.recolors].each_with_index.map do |colors, set|
                own = palette ? [[@art.sprite_palette_at(palette), colors.drop(1)]] : []
                own + worn.map { |shown, worn_sets| [@art.sprite_palette_at(shown), worn_sets.fetch(set)] }
              end
              runtime_call("rt_colors_hold", [LongAddress.new(held_colors_label([:sprites, name]) { sets }), which])
            end

            # Each list of sprite colours some scenes keep to themselves: the number it was told last, by its
            # name, from power-on the one naming none, as the interpreter keeps it (Reference @held_colors).
            def keep_sprite_color_choices
              held = @sprite_colors ? changing_sprite_lists.select { |list| colors_scenes_of_list(list) } : []
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
              return emit_walking_background_colors(which, bg) if bg.several_sets?

              label = on_third_layer?(bg) ? third_layer_colors_label(bg) : background_colors_label(bg)
              runtime_call("rt_colors_hold", [LongAddress.new(label), which])
            end

            # The table of the third layer's sets of colours for +bg+, which is on it: its own, and one
            # for each list it borrows. The layer's eight lists of three are in the backgrounds' first
            # lists (Art#reserve_bar_palettes), so each set writes those whole (Art#bar_held_set).
            def third_layer_colors_label(bg)
              held_colors_label([:third_layer, bg.object_id]) do
                [nil, *bg.recolors.each_index].map { |step| @art.bar_held_set(step && bg.list_swaps(step), colors_scene_of(bg)) }
              end
            end

            # The table of +bg+'s sets of colours, its own and one for each list it borrows, in +area+
            # (an Art::AreaKey) for a background walking between areas.
            def background_colors_label(bg, area = nil)
              held_colors_label([:background, bg.object_id, area]) do
                [nil, *bg.recolors.each_index].map { |step| background_held_set(bg, step, area) }
              end
            end

            # A background walking between areas keeps its lists' palettes in each area's own copy of
            # the colours, so a list it borrows is written into the area up (#area_up_var) alone. An area
            # not up gets the list as it comes in (#emit_area_up). None up, after a scene brought its own
            # tiles in over them, writes nothing.
            def emit_walking_background_colors(which, bg)
              done = fresh("walking_colors")
              bg.sets.each_index do |set|
                key = area_key(bg, set)
                other = fresh("not_area")
                jump_unless(Build.binop(:==, Build.var_ref(area_up_var), Build.int(area_keys.index(key))), other)
                runtime_call("rt_colors_hold", [LongAddress.new(background_colors_label(bg, key)), which])
                @asm.brl(done)
                @asm.label(other)
              end
              @asm.label(done)
            end

            # Each background whose list the game must write again later: one a scene shows and draws
            # with other colours, in a game of screen colours, and one walking between areas that draws
            # with other colours. The number it was told last, by its name, from power-on the one naming
            # none, as the interpreter keeps it by name (Reference @bg_colors).
            def keep_background_color_choices
              recolored = backgrounds_declared.select do |bg|
                !Array(bg.recolors).empty? && ((@screen_colors && bg.scene) || bg.several_sets?)
              end
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
            # A background walking between areas keeps a set for each +area+ (an Art::AreaKey), since each
            # area has its own copy of the colours.
            def held_lists_key(bg, area = nil) = [colors_scene_of(bg), bg.name, *area]

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

            # The colours every screen keeps, in a game of screen colours: all of them made before any
            # scene takes its copy (Art#background_palettes): each tile on the maps of what every screen
            # shows, and each one the game changes a cell of it to. A tile of its set that is on neither
            # is never drawn, so it takes no colours. Then the runs a scene keeps to itself, which are
            # the first to take a copy.
            #
            # In a game with a background walking between areas the same goes for every area's copy, so
            # every other background's cells, a scene's too, are made before the first area takes one.
            def make_shared_background_colors
              walking = walking_backgrounds
              return unless @screen_colors || @scene_background_tiles || !walking.empty?

              plain = backgrounds_declared - walking
              plain.reject(&:scene).each { |bg| make_cells_shown(bg) }
              @tile_runs.each_index { |number| make_run_art(number) unless @run_places[number] }
              return if walking.empty?

              plain.select(&:scene).each { |bg| make_cells_shown(bg) }
              walking.each { |bg| make_cells_shown(bg) }
            end

            # Each cell +bg+ can show: those on its maps, and each tile the game changes a cell to.
            def make_cells_shown(bg)
              shown = bg.every_map.flat_map { |map| map.flat_map { |row| Array(row) } }
              changed = @set_tiles_by_name.fetch(bg.name, []).flat_map(&:tiles_named)
              (shown + changed).uniq.each { |tile| cell_of(bg, tile) if tile.nil? || tile < bg.tiles.length }
            end

            # A scene taking over, in a game of screen colours: its sets into the colours drawn now and
            # the copy the blank sends, through whatever fade is in force, and the list each of its
            # backgrounds was told to draw with set again over them. They go out in the blank that
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
                emit_sprite_list_write(list, Build.var_ref(choice)) if colors_scenes_of_list(list).include?(scene)
              end
            end

            # What a background's palettes hold at its step +step+ (nil for its own colours): each list
            # it is drawn from, by place, as the list named for that step gives (Assets::Recolor).
            #
            # Lists that share a palette (Art#held_offset_of) are one set, each list's colours where
            # it starts in the palette, so the write of one leaves none of the others' as zeros.
            def background_held_set(bg, step, area = nil)
              swaps = step && bg.list_swaps(step)
              lists = ((@background_lists || {})[held_lists_key(bg, area)] || {}).map do |list, (palette, image)|
                swapped = swaps && swaps[list]
                colors = (1...image.colors.length).map { |place| (swapped && swapped[place]) || image.colors[place] }
                [palette, @art.held_offset_of(held_list_key(bg, list, area)), colors]
              end
              lists.group_by(&:first).map do |palette, held|
                [@art.background_palette_at(palette), held.sort_by { |_, offset, _| offset }.flat_map(&:last)]
              end
            end

            # The palette of the list +image+ is drawn from, in a background the game draws with other
            # colours, and nil in any other. A list a tile painted from a list is drawn from keeps its
            # palette's first place, since the game writes those tiles' places as they are in the list
            # (Runtime::Picture's rt_tile_run_copy); any other may share its palette with the
            # background's other lists (Art#held_background_palette).
            #
            # On a background walking between areas the palette is in the copy of the colours of +area+
            # (an Art::AreaKey), the area the tile is in.
            def held_background_palette(bg, image, area = nil)
              return nil if Array(bg.recolors).empty?

              list = image.list_drawn_from
              colors = image.colors.drop(1).map { |color| color & 0x7FFF }
              owner = held_lists_key(bg, area) unless @tile_runs.any? { |run| run.list_drawn_from == list }
              palette = @art.held_background_palette(held_list_key(bg, list, area), colors, scene: area || colors_scene_of(bg), owner: owner)
              ((@background_lists ||= {})[held_lists_key(bg, area)] ||= {})[list] = [palette, image]
              palette
            end

            # What +bg+'s held +list+ is kept under in the Art.
            def held_list_key(bg, list, area = nil) = [:backgrounds, *held_lists_key(bg, area), list]

            # The palette of a run on a background the game draws with other colours: the one its list has
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
            # screen. Too many for the whole game is not yet the end of it (SNES#build), and nor is
            # too many for a scene where some are lists other scenes draw with too: built again, each
            # of those is kept by its own scenes alone (+sprite_colors+ of :lists).
            def held_palette_or_refuse
              yield
            rescue Art::TooManySpriteColors
              raise
            rescue Art::TooMuch => e
              raise Art::TooManySceneSpriteLists, e.message if @sprite_colors == true && sprite_lists_of_some_scenes?

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

            # A `screen` other than the game's own that sets a backdrop the game's does not, somewhere
            # it cannot come up by: on a painted screen, or anywhere but the top of a scene.
            def refuse_backdrops_of_its_own!
              handover = @cache.handover
              game_backdrop = handover.game_backdrop
              said = @program.walk.select { |node| node.kind == :screen && node.backdrop && node.backdrop != game_backdrop }
              return if said.empty? || (!painted? && said.all? { |node| handover.scene_screen?(node) })

              refuse_unmade!("a scene that says a backdrop of its own (`screen ... backdrop:`)")
            end

            # Whether a scene of +program+ sets a backdrop the game's does not, which colour 0 is
            # changed to as it takes over (Runtime::Tint's rt_backdrop_hold).
            def self.scene_backdrops?(program, handover = IR::SceneHandover.of(program))
              return false if Lowering::Paint.painted?(program)

              handover.scene_screens.any? { |_, screen| screen.backdrop && screen.backdrop != handover.game_backdrop }
            end

            # A scene taking over, in a game whose scenes differ in their backdrop: colour 0 changed
            # to its own, or the game's where it names none. It goes out with the scene's colours and
            # maps (Runtime::Picture's "Together"), through whatever fade is in force.
            def emit_scene_backdrop(arrival)
              return unless @cache.facts.scene_backdrops? && arrival.backdrop

              runtime_call("rt_backdrop_hold", [Build.int(arrival.backdrop & 0x7FFF)])
            end

            # Whether the backdrop follows a list of colours the game recolours (IR::Nodes::ColorList#backdrop_place).
            def self.backdrop_follows_list?(program) = !followed_list(program).nil?

            def self.followed_list(program) = program.walk.find { |node| node.kind == :color_list && node.backdrop_place }

            # A backdrop that follows the list +node+ is telling to hold another set: colour 0 of the colour
            # memory, which is the backdrop and no list's place, is given the backdrop's colour in that set
            # (Runtime::Tint's rt_backdrop_from), on the same pass as the list's own colours and through the
            # same fade. Nothing for any other list.
            def emit_backdrop_follows(node)
              list = Picture.followed_list(@program)
              return unless list&.name == node.name

              runtime_call("rt_backdrop_from", [LongAddress.new(BACKDROP_COLORS), node.which])
            end

            BACKDROP_COLORS = "art backdrop colors"

            # The table rt_backdrop_from reads: how many sets, the declared one among them, then the backdrop's
            # colour in each, the declared one first.
            def write_backdrop_colors(data)
              list = Picture.followed_list(@program) or return

              sets = [list.colors, *list.recolors]
              data.label(BACKDROP_COLORS)
              data.data_words(sets.length, *sets.map { |set| set.fetch(list.backdrop_place) & 0x7FFF })
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
              tables, *pieces = art_tables(pieces_apart: false)
              tables, *pieces = art_tables(pieces_apart: true) if tables.size > Linker::BANK_SIZE
              [tables, *pieces, *bytes_section("art background tiles", @art.background_tile_data(power_on_background_key)),
               *bytes_section("art sprite tiles", @art.sprite_tile_data(opening_scene)), *scene_sprite_tile_sections,
               *scene_background_tile_sections, *area_tile_sections,
               *@art.grids.map { |grid| bytes_section(grid_label(grid.number), grid.bytes) },
               *(painted? ? paint_sections : []), *collision_sections]
            end

            # How many bytes of a game's sprite pieces go in one section, when they do not fit beside
            # its other tables.
            PIECES_A_SECTION = 16_384

            # The art's tables, then the sections of sprite pieces moved out of them. A game with many
            # pictures, each cut into pieces, can have more pieces than a bank holds. A picture finds
            # its pieces by a full address, so with +pieces_apart+ they go in banks of their own, which
            # a game that fits has no use for.
            def art_tables(pieces_apart:)
              data = W65816.new("art", holds: ART)
              apart = []
              data.label("art background tiles bytes")
              data.data_words(@art.background_tile_data(power_on_background_key).bytesize)
              data.label("art sprite tiles bytes")
              data.data_words(@art.sprite_tile_data(opening_scene).bytesize)
              unless painted? # Lowering::Paint's colours, then
                data.label("art colors")
                data.data_bytes(@art.cgram(power_on_colors_key).bytes)
              end
              data.label("art sprite pictures")
              pictures = @art.sprite_pictures.values.sort_by(&:number)
              data.data_longs(pictures.map { |picture| pieces_label(picture.number) })
              pictures.each do |picture|
                holder = data
                if pieces_apart
                  apart << W65816.new("art pieces part #{apart.length + 1}", holds: ART) if apart.empty? || apart.last.here > PIECES_A_SECTION
                  holder = apart.last
                end
                write_sprite_pieces(holder, picture)
              end
              write_held_colors(data)
              write_backdrop_colors(data)
              data.label("art grids")
              @art.grids.each do |grid|
                data.data_longs(grid_label(grid.number))
                data.data_bytes(0)
                data.data_words(grid.bytes.bytesize, grid.size_bits, grid.columns)
              end
              write_scene_background_tile_tables(data)
              write_area_tile_tables(data)
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
              [data.section, *apart.map(&:section)]
            end

            def write_sprite_pieces(data, picture)
              data.label(pieces_label(picture.number))
              data.data_words(picture.pieces.length)
              picture.pieces.each do |piece|
                data.data_words(piece.dx, piece.dy, piece.tile | (piece.palette << 9) | SPRITE_IN_FRONT)
                data.data_words(piece.big ? Runtime::Picture::SPRITE_SIZE_BIT : 0) if sprite_squares?
              end
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
              # A scene's own tiles go in over an area's, so no area is up after them.
              statement(Build.set(area_up_var, Build.int(-1))) if @scene_background_tiles && !area_keys.empty?
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
              emit_scene_sprite_tiles_held(scene)
            end

            # A scene picked inside a test, after the game changed the variable that picks it in the
            # same pass: the frame of that pass shows the scene up as the pass started, with its
            # sprites, since the loop notes the number for the frame's sprites as the pass starts
            # (IR::Frames.loop_in_console_order). The arriving scene's tiles would go in under the
            # leaving scene's sprites, so they are held for one blank (Runtime::Picture's
            # SCENE_TILES_HELD) and go in after the next pass, the first to show the arriving scene's
            # sprites. The note and the number differ only then: a dispatch at the top of the loop
            # is noted as it reads the number. A scene picked by more than one variable is not held.
            def emit_scene_sprite_tiles_held(scene)
              vars = scene_dispatch_vars.fetch(scene, [])
              return unless vars.one?

              read = Frames.scene_read_name(vars.first)
              return unless @variables.key?(read)

              shown = fresh("scene_tiles_shown")
              jump_unless(Build.binop(:!=, Build.var_ref(vars.first), Build.var_ref(read)), shown)
              @asm.lda(1)
              @asm.sta(@asm.abs(@memory[Runtime::Picture::SCENE_TILES] + Runtime::Picture::SCENE_TILES_HELD))
              @asm.label(shown)
            end

            # The variables each scene is picked by, by the scene.
            def scene_dispatch_vars
              @scene_dispatch_vars ||= @program.walk.select { |node| Frames.scene_dispatch?(node) }
                                               .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |node, vars|
                node.clauses.each { |_, target| vars[target] |= [node.var] }
              end
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

            # --- backgrounds that walk between areas ---
            #
            # A background that walks between areas (`tiles: { shrine: ..., clearing: ... }`) shows one
            # area's tiles at a time: video memory has room for one area's beside what every screen
            # keeps, and the areas take turns in it. Each area keeps its own copy of the tiles and the
            # sets of colours (Art::AreaKey), made after everything else on the screen is made
            # (#make_shared_background_colors), so an area's tiles and colours land past all of those.
            # Walking into another area (#emit_area_up) brings in its tiles the way a scene taking over
            # brings in its own (Runtime::Picture's rt_scene_background_tiles: the display off for the
            # copy, as a Super Nintendo game turns it off to load a screen, and on again once the pass's
            # picture is in), and its colours through the fade in force (Runtime::Tint's rt_colors_hold).
            # Then the map goes up as any map does, so no frame shows a map over the wrong area's tiles.
            # Tiles painted from a list (`tile_pictures` too) keep fixed places, made before any area
            # takes its copy, so an area showing one names the run's own tiles in every area.

            # Whether a background of +program+ walks between areas.
            def self.walks_areas?(program) = program.walk.any? { |node| node.kind == :background && node.several_sets? }

            def walking_backgrounds = backgrounds_declared.select(&:several_sets?)

            # The area +set+ (counted in +bg+'s sets) of +bg+'s, as the Art keeps it.
            def area_key(bg, set)
              Art::AreaKey.new(scene: bg.scene, area: bg.sets.fetch(set), tiles_base: tiles_scene_of(bg), colors_base: colors_scene_of(bg))
            end

            # Every area of the game, numbered by its place here: the number the area up is kept as.
            def area_keys = @area_keys ||= walking_backgrounds.flat_map { |bg| bg.sets.each_index.map { |set| area_key(bg, set) } }.uniq

            # The area tile +tile+ of +bg+ belongs to.
            def area_of_tile(bg, tile) = area_key(bg, bg.set_starts.rindex { |start| start <= tile })

            # The area up as the game starts: the first area of a background every screen shows, or of
            # one the opening scene shows. Nil where neither walks.
            def power_on_area
              walking = walking_backgrounds
              bg = walking.find { |one| one.scene.nil? } || walking.find { |one| one.scene == opening_scene }
              area_key(bg, 0) if bg
            end

            def power_on_background_key = power_on_area || opening_scene
            def power_on_colors_key = power_on_area

            # Which area's tiles are in video memory, by its number in #area_keys; -1 for none, after a
            # scene brought its own tiles in over them.
            def area_up_var
              @area_up_var ||= keep_local(:area_up, start: power_on_area ? area_keys.index(power_on_area) : -1)
            end

            # Bring area +key+ of +bg+ in, unless it is up: its tiles and its colours, for the next blank.
            # With +colors_always+ its colours come in either way, as a scene taking over has just copied
            # its own over them.
            def emit_area_up(bg, key, colors_always: false)
              number = area_keys.index(key)
              up = area_up_var
              same = fresh("area_up")
              jump_unless(Build.binop(:!=, Build.var_ref(up), Build.int(number)), same)
              statement(Build.set(up, Build.int(number)))
              runtime_call("rt_scene_background_tiles", [LongAddress.new(area_tiles_table_label(number))])
              emit_area_colors(bg, key) unless colors_always
              @asm.label(same)
              emit_area_colors(bg, key) if colors_always
            end

            # Area +key+'s colours, then the list +bg+ was last told to draw with written over its own
            # (Reference keeps that by the background's name, whichever area is up, so an area walked
            # back to draws with it again).
            def emit_area_colors(bg, key)
              label = held_colors_label(:areas) { area_keys.map { |one| @art.scene_colors(one) } }
              runtime_call("rt_colors_hold", [LongAddress.new(label), Build.int(area_keys.index(key) - 1)])
              choice = @background_color_choices[bg.name]
              runtime_call("rt_colors_hold", [LongAddress.new(background_colors_label(bg, key)), Build.var_ref(choice)]) if choice
            end

            def area_tiles_label(number) = "art background tiles of area #{number}"
            def area_tiles_table_label(number) = "art background table of area #{number}"

            # Each area's tiles past what every screen keeps (Art#area_background_tiles).
            def area_tile_sections
              area_keys.each_index.flat_map { |number| bytes_section(area_tiles_label(number), @art.area_background_tiles(area_keys[number]).last) }
            end

            # For each area, where its tiles are on the cartridge, how many bytes and where they go: the
            # table rt_scene_background_tiles reads, as #write_scene_background_tile_tables writes a scene's.
            def write_area_tile_tables(data)
              area_keys.each_with_index do |key, number|
                first, bytes = @art.area_background_tiles(key)
                data.label(area_tiles_table_label(number))
                data.data_longs(area_tiles_label(number))
                data.data_bytes(0)
                data.data_words(bytes.bytesize, Runtime::Picture::BG_TILES + (first * Art::TILE_BYTES / 2))
              end
            end

            # What this build does not make yet of a background walking between areas.
            def refuse_unmade_walking!(bg)
              refuse_unmade!("a background walking between areas on a status bar or held above a row") if bg.held_to_rows?
              if bg.scene.nil? && (@screen_colors || @scene_background_tiles)
                refuse_unmade!("a background walking between areas on every screen, in a game whose scenes bring in their own colours or tiles")
              end
            end

            ART = W65816::Holding.new(what: "the game's pictures", fix: "use fewer different pictures and maps")

            # A sprite row's attributes, the high byte of its tile word: in front of every background
            # (priority 3). A sprite behind a background has the difference from its own priority
            # (#sprite_depths) taken off as it is placed.
            SPRITE_IN_FRONT = 0x3000

            # The priority bits of a sprite row.
            SPRITE_PRIORITY_SHIFT = 12

            # Sprites in layers, among the backgrounds (#assign_background_layers has put each
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
                      # A bar on the third layer is behind every sprite, whatever its priority, and
                      # the bar's rows show no other layer: so there a sprite can be behind a
                      # background and still be over the bar, as the interpreter draws it.
                      if priority != 3 && !@third_layer && screenful.scenery.any?(&:bar?)
                        refuse_unmade!("a status bar beside a sprite behind a background")
                      end
                      # A background held above a row there is behind every sprite too, and the
                      # interpreter draws it over one the stack puts behind it. One that keeps the
                      # sprites out above its row (`alone: :without_sprites`) never shows beside a
                      # sprite: above the row the line table shows it alone, and below it, it is not drawn.
                      sprite_under_held = scenery.any? do |bg|
                        on_third_layer?(bg) && !bg.hides_sprites && screenful.depths.of_scenery(bg) > level
                      end
                      refuse_unmade!("a sprite behind a background held above a row beside two other backgrounds") if sprite_under_held
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
            def bent_layers = painted? ? [] : bends.map { |bend| layer_of(background_declared_for(bend.node)) }.uniq

            # Whether the game's bends are kept as a step for each band (Runtime::Picture, "A bend that
            # holds one value for whole bands of rows"): every bend has bands, few enough to keep.
            def bends_by_bands?
              bend_bands.all? && bend_bands.all? { |firsts| band_steps(firsts).sum(&:length) <= Runtime::Picture::MOST_BAND_STEPS }
            end

            # BGMODE's size bits for the layers drawn from 16×16 tiles: BG1's is bit 4, BG2's bit 5, told
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

            # MOSAIC's low four bits for a game that pixelates (Runtime::Mosaic): the layers whose
            # backgrounds are put in blocks, BG1's the lowest. A painted screen is one picture, the
            # text over it included, so every layer it shows is in blocks, as the interpreter shows
            # the whole of a painted picture in blocks. On a tiled screen a background is in blocks
            # unless the game's place leaves it as drawn (`under:`), or it is a status bar the game
            # does not put in blocks too (`status_bar: true`), as Reference#paint_scenery, #paint_status_bar
            # and #place_blocks decide.
            #
            # A layer whose scenes differ in that (a menu's status bar as drawn, and a stage's clouds
            # in blocks, on one layer) is among these bits too, and each scene taking over notes the
            # layers it leaves as drawn (#emit_scene_mosaic), which the blank takes out of the byte
            # (Runtime::Mosaic::KEPT_LAYERS). A layer one background holds in every scene, or none
            # does, keeps its one answer, and a game with no such layer has none of it.
            def mosaic_backgrounds
              return ALL_MOSAIC_LAYERS if painted?

              @layers.reduce(0) { |bits, (bg, layer)| background_in_blocks?(bg) ? bits | (1 << layer) : bits }
            end

            ALL_MOSAIC_LAYERS = 0x0F

            # Reference#in_blocks? and #paint_status_bar, all but the size: whether +bg+ is in blocks while
            # the picture is.
            def background_in_blocks?(bg)
              choice = blocks_choice
              (!bg.bar? || choice.bars) && !choice.kept.include?(bg.name)
            end

            # What the program chose for its blocks, worked out once: the names left as drawn
            # (`under:`), and whether a status bar is in blocks (`status_bar: true`).
            BlocksChoice = Data.define(:kept, :bars)

            # Raises for a program that chooses both ways (Blocks.bar_in_blocks!), which the builder
            # refuses before it gets here.
            def blocks_choice
              @blocks_choice ||= begin
                places = Blocks.places(@program)
                kept = places.first ? Stacking.at_or_above(Stacking.picture(@program), places.first).map(&:name) : []
                BlocksChoice.new(kept: kept, bars: Blocks.bar_in_blocks!(@program, LoweringError))
              end
            end

            # The layers whose backgrounds are in blocks in one scene and not in another, a bit each.
            def mosaic_layers_by_scene
              @layers.group_by { |_, layer| layer }.sum do |layer, held|
                held.map { |bg, _| background_in_blocks?(bg) }.uniq.length > 1 ? 1 << layer : 0
              end
            end

            # A scene taking over, in a game with a layer whose scenes differ (#mosaic_backgrounds):
            # the layers of those whose background in this scene is left as drawn, noted for the blank.
            def emit_scene_mosaic(arrival)
              return unless Runtime::Mosaic.kept?(@memory)

              differing = mosaic_layers_by_scene
              return if differing.zero?

              kept = arrival.scenery.reduce(0) do |bits, bg|
                @layers.key?(bg) && !background_in_blocks?(bg) ? bits | (1 << layer_of(bg)) : bits
              end
              Runtime::Mosaic.reserve_kept_layers(@memory)
              @asm.lda(kept & differing)
              @asm.sta(@asm.abs(@memory[Runtime::Mosaic::KEPT_LAYERS]))
            end

            # Reference#exec_pixelate: blocks of this size from the next picture on (Runtime::Mosaic).
            # Which backgrounds are in them is settled as the cartridge is built (#mosaic_backgrounds).
            def emit_pixelate(node) = runtime_call("rt_mosaic", [node.size])

            # Whether +program+ pixelates, which the runtime then carries the mosaic for.
            def self.pixelates?(program) = program.walk.any? { |node| node.kind == :pixelate }

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

              # Put up again, it keeps the cells its layer holds (SceneryWrites#emit_put_up_keeping_cells).
              emit_put_up_keeping_cells(node, layer_of(node)) { |kept| emit_put_up(node, keeps_cells: kept) }
              emit_bar_beside(node)
            end

            # +keeps_cells+ puts it up keeping the cells its layer holds: nothing is copied, and the view goes
            # back to the corner as rt_background_put_up puts it there. Otherwise its declared map is copied.
            def emit_put_up(bg, keeps_cells: false)
              if keeps_cells
                runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), Build.int(0), Build.int(0)])
              else
                # A walking background goes up in its first area, whose colours come in again since a
                # scene taking over has just copied its own over them.
                emit_area_up(bg, area_key(bg, 0), colors_always: true) if bg.several_sets?
                runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, 0).number), Build.int(1)])
              end
              # A status bar put up shows from the top it was declared with (Reference#bar_top_shown), and
              # covers sprites as that bar was last set to (IR::SceneHandover#bar_covers_on_put_up).
              if bg.bar?
                runtime_call("rt_bar_place", [Build.int(layer_of(bg)), Build.int(bg.bar_top)])
                covers = @handover.bar_covers_on_put_up(bg)
                runtime_call("rt_bar_covers", [covers]) if covers
              end
              if bg.above_row
                alone = @alone_flag_in_line_table ? [Build.int(bg.shown_above_row)] : []
                runtime_call("rt_background_held_above", [Build.int(layer_of(bg)), Build.int(bg.above_row), *alone])
              end
              [corner_note(layer_of(bg)), (bar_note if bg.bar?)].compact.each { |note| statement(Build.set(note, 1)) }
            end

            # The two layers a background can be on.
            LAYERS = [0, 1].freeze

            # Every layer a background goes up on, the third among them where the game has one: those a put-up
            # holds at its corner through its pass (SceneryWrites#keep_corner_notes). A status bar's top is held
            # by a note of its own, since a bar is placed by its top rather than its layer's view.
            def corner_layers = @third_layer ? [*LAYERS, THIRD_LAYER] : LAYERS

            # Which of the two layers each background is on (#assign_background_layers). A scene's own
            # scenery is in front of the scenery every screen shows, as the interpreter paints it over
            # what is up already, and within each the one drawn last is in front — the one declared
            # last, or the one in the front-most layer the game's `layers` name (IR::Stacking, which
            # IR::SceneHandover hands the scenery over in the order of): so the scenes' own take the
            # front layers, BG1 first, as many as the scene with the most has, and the scenery every
            # screen shows the layers behind those. So a stack that puts a scene's own background
            # behind one every screen shows is not made yet. (Every sprite is in front of every
            # background, SPRITE_IN_FRONT: a background in front of a sprite needs the sprite in a
            # layer, which #refuse_unmade_picture! refuses.)
            #
            # A status bar or a background held above a row on the third layer (Picture.third_layer?) is
            # left out of that count and order: it is on THIRD_LAYER whichever screen shows it, and the
            # other two layers are shared out as they are in a game with neither.
            def assign_background_layers
              @layers = {}.compare_by_identity
              always = layered_scenery(@handover.always_up.scenery)
              own = @scenes.keys.map { |scene| layered_scenery(@handover.arrival(scene).scenery) }
              @scene_layers = own.map(&:length).max || 0
              if always.length + @scene_layers > BACKGROUND_LAYERS
                refuse_unmade!(@third_layer ? "more than two backgrounds on the screen at once beside a status bar or a background held above a row" : "more than two backgrounds on the screen at once")
              end
              @scene_bars = @scenes.keys.any? { |scene| @handover.arrival(scene).scenery.any?(&:held_to_rows?) }
              refuse_unmade!("a background kept above a row beside a status bar") if Picture.background_rows_held?(@program) && Picture.status_bar?(@program)
              @plan.refuse_unmade_stacking!(NotMadeYet, part: "the picture") { |bg| !on_third_layer?(bg) }
              refuse_unmade_bends!
              always.each_with_index { |bg, i| @layers[bg] = @scene_layers + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
              make_third_layer_art if @third_layer
              refuse_unmade_see_through!
            end

            # The layer Runtime::Picture keeps a status bar or a background held above a row on beside
            # two backgrounds, or a status bar beside a sprite behind a background (BG3).
            THIRD_LAYER = 2

            # +scenery+ less a background on the third layer.
            def layered_scenery(scenery) = @third_layer ? scenery.reject(&:held_to_rows?) : scenery

            # Whether +bg+ is on the third layer.
            def on_third_layer?(bg) = @third_layer && bg.held_to_rows?

            # +bg+ on the third layer, as a refusal names it (the answers name when one is there).
            def third_layer_refusal_words(bg) = bg.bar? ? "a status bar on the third layer" : "a background held above a row beside two other backgrounds"

            # The third layer's tiles and colours, made before any other background's, so that the lists
            # of the backgrounds its colours take are the first (Art#reserve_bar_palettes) and its tiles
            # are among the places it can name. Every tile its maps show and every tile the game sets in
            # it is made now, so none comes later, after a scene has taken its copy of the tiles.
            def make_third_layer_art
              refuse_unmade!("two backgrounds held to rows on one screen beside two other backgrounds") if Stacking.screenfuls(@program).any? { |screenful| screenful.scenery.count(&:held_to_rows?) > 1 }
              # The layer's eight lists are one set of colours, written whole by each walk
              # (Art#bar_held_set), so two declarations walking theirs would write over each other's.
              walking = backgrounds_declared.select { |bg| bg.held_to_rows? && !Array(bg.recolors).empty? }
              refuse_unmade!("two backgrounds on the third layer drawn with other colours (`draw_with`)") if walking.length > 1
              on_third = backgrounds_declared.select(&:held_to_rows?)
              # In a game of screen colours, each scene keeps its own third layer's lists, where no
              # background on the layer is every screen's (Art#keep_bar_lists_by_scene!).
              @art.keep_bar_lists_by_scene!(on_third.map(&:scene).uniq) if @screen_colors && on_third.all?(&:scene)
              on_third.each do |held|
                @layers[held] = THIRD_LAYER
                refuse_unmade_third_layer!(held)
                held.every_map.each_index { |which| grid_of(held, which) }
                @set_tiles_by_name.fetch(held.name, []).flat_map(&:tiles_named).grep(Integer)
                        .each { |tile| cell_of(held, tile) if tile < held.tiles.length }
              end
              @art.reserve_bar_palettes
            end

            # What a background on the third layer cannot be yet.
            def refuse_unmade_third_layer!(held)
              words = third_layer_refusal_words(held)
              refuse_unmade!("#{words} drawn from 16×16 tiles") unless held.tile_w == 8
              # The two windows are the two ordinary layers' (Runtime::BackgroundBox). A background
              # only hidden whole (`hide`) is a box with nothing in it here, so it needs one too.
              if held.boxed
                hidden_whole = @program.walk.any? { |node| node.kind == :box_background && node.name == held.name && node.whole }
                refuse_unmade!(hidden_whole ? "#{words} switched off and on (`hide`, `show`)" : "#{words} held to a box (`show_only_inside`)")
              end
              refuse_unmade!("#{words} bent row by row") if bends.any? { |bend| bend.background == held.name }
              refuse_unmade!("#{words} showing tiles painted from a list") if @tile_runs.any? { |run| held.tiles.intersect?(Array(run.tiles)) }
              return unless held.above_row

              # The colour math would mix the held background with the sub screen above its row, where
              # the interpreter mixes it with nothing.
              refuse_unmade!("#{words} in a see-through layer") if SeeThrough.layer(@program, held.layer)
              refuse_unmade!("#{words} beside a see-through layer of sprites") if mixed_sprites_above_row?(held)
              # One the game shows alone (`alone: true`) is drawn alone above its row by the
              # interpreter too, so where it is in the stack and what its see-through pixels show
              # are the same on both.
              return if held.alone

              refuse_unmade!("#{words} behind another background") if held_behind_scenery?(held)
              refuse_held_see_through!(held)
            end

            # Whether sprites in a see-through layer can show above +held+'s row. The line table shows
            # the third layer alone there, with the sprites unless the game keeps them out
            # (`alone: :without_sprites`), so a see-through layer of other backgrounds is never on the
            # main screen above the row and the colour math has nothing to mix there: the bar shows as
            # drawn, as the interpreter draws it. A see-through sprite would be mixed with the sub
            # screen, the layers behind it below the row, where the interpreter mixes it with the bar.
            def mixed_sprites_above_row?(held)
              return false if held.hides_sprites

              SeeThrough.layers(@program).any? { |layer| !Picture.see_through_parts(@program, layer, @cache.stacking).sprites.empty? }
            end

            # Whether a screen showing +held+ draws another background in front of it: one after it in
            # the stack's order, or a scene's own where +held+ is every screen's (the interpreter paints
            # a scene's own over what every screen shows). The third layer is shown alone above the row,
            # so it is in front there whatever the stack says.
            def held_behind_scenery?(held)
              Stacking.screenfuls(@program).any? do |screenful|
                scenery = screenful.scenery
                same = ->(bg) { bg.name == held.name && bg.scene == held.scene }
                next false unless scenery.any?(&same)

                !same.call(scenery.last) || (held.scene.nil? && scenery.any?(&:scene))
              end
            end

            # A background held above a row on the third layer shows alone above its row, as a Super
            # Nintendo game's bar does: the line table shows the third layer and the sprites there, and
            # the other two layers from the row down (Runtime::Picture#emit_bar_table). The third layer
            # is behind the other two in mode 1 (and, with BGMODE's bit for it, in front of the sprites
            # too), so showing all three above the row would put the arena over the bar. The
            # interpreter draws the backgrounds behind it there too, where it is see-through. So a held
            # background that can be see-through on its rows is refused: a tile with a see-through
            # pixel, or a cell left empty that can come into view. Without a scroll of its own the cells
            # in view are the ones its corner shows; with one, every cell of its grid. One the game
            # shows alone (`alone: true`) is not asked: the interpreter shows the backdrop there too.
            def refuse_held_see_through!(held)
              subject = "The background :#{held.name} is held above a row beside two other backgrounds"
              why = "On a Super Nintendo, that background goes on a layer that shows alone above its row. " \
                    "The backgrounds behind it cannot show through it there."
              alone = "Or, to show the backdrop there, give :#{held.name} `alone: true`."
              tile = held.tiles.find { |name| (0...64).any? { |at| @cache.image(picture_named(name)).tile_see_through_at?(at) } }
              if tile
                raise Art::HeldArtSeeThrough, "#{subject}, and its tile :#{tile} has see-through pixels. #{why} " \
                                              "To fix this, draw the tile :#{tile} with no see-through pixels. #{alone}"
              end
              return unless held_cells_empty?(held)

              raise Art::HeldArtSeeThrough, "#{subject}, and its map has empty cells that can show above the row. #{why} " \
                                            "To fix this, put a tile in each cell of its map. If the game does not scroll " \
                                            "it, only the cells above the row must have a tile. #{alone}"
            end

            # Whether a cell of +held+'s maps that can come into view above its row is empty. (A
            # `set_tile` never empties one: it names a tile the background has, and a picked tile
            # that stands for none changes nothing, Reference#exec_set_tile.)
            def held_cells_empty?(held)
              scrolled = @program.walk.any? { |node| node.kind == :scroll_background && node.name == held.name }
              held.every_map.any? do |map|
                columns, rows = TileMap.grid(map)
                unless scrolled
                  rows = [rows, (held.above_row + held.tile_h - 1) / held.tile_h].min
                  columns = [columns, (Console::SUPER_NINTENDO.screen_width + held.tile_w - 1) / held.tile_w].min
                end
                (0...rows).any? { |row| (0...columns).any? { |column| (tile = Array(map[row])[column]).nil? || tile.negative? } }
              end
            end

            def layer_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no layer" }

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
              emit_scene_mosaic(arrival)
              # (A scene's own status bar on the third layer is a scene's own scenery on no layer of
              # the two.)
              own_scenery = !@scene_layers.zero? || scene_bars?
              emit_scene_colors(scene, arrival) unless own_scenery
              return unless own_scenery

              emit_layers_straight_for(arrival)
              emit_tile_sizes_for(arrival)
              emit_scene_colors(scene, arrival)
              arrival.map_choices.each { |var| store_number(place_of(var), 0) }
              arrival.scenery.each { |bg| emit_put_up(bg) }
              emit_boxes_forgotten(arrival)
              ((0...@scene_layers).to_a - arrival.scenery.map { |bg| layer_of(bg) }).each do |layer|
                runtime_call("rt_background_put_up", [Build.int(layer), Build.int(empty_grid.number), Build.int(1)])
              end
              runtime_call("rt_bar_gone", []) if scene_bars? && arrival.scenery.none?(&:held_to_rows?)
              emit_bar_beside_arrival(arrival)
            end

            # The layers some scene bends and the one taking over does not: their rows go straight.
            def emit_layers_straight_for(arrival)
              bent = bends.reject { |bend| scenes_showing(bend).nil? }.map { |bend| background_declared_for(bend.node) }
              return if bent.empty?

              up = bent.select { |bg| scenery_holds?(arrival.scenery, bg) }
              straight = bent.map { |bg| layer_of(bg) }.uniq - up.map { |bg| layer_of(bg) } # two scenes can bend one layer
              @asm.lda(straight.sum { |layer| 1 << layer })
              @asm.sta(@asm.abs(@memory[Runtime::Picture::LAYERS_STRAIGHT]))
            end

            # Whether a scene of the game puts up a status bar of its own, which leaves as the next
            # scene takes over (Runtime::Picture's rt_bar_gone).
            public def scene_bars? = @scene_bars

            # Whether a map handed over takes the cells queued for its background out (rt_cells_drop).
            public def cells_dropped? = @cells_dropped || false

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
              if on_third_layer?(bg)
                owner = Art::ThirdLayerOwner.new(name: bg.name, held_above: !bg.above_row.nil?)
                return @art.bar_cell(@cache.image(picture_named(name)), owner: owner, tile: name, walks: !Array(bg.recolors).empty?,
                                                                        scene: colors_scene_of(bg))
              end

              @run_cells.fetch(name) do
                image = @cache.image(picture_named(name))
                area = area_of_tile(bg, tile) if bg.several_sets?
                held = held_background_palette(bg, image, area)
                offset = held ? @art.held_offset_of(held_list_key(bg, image.list_drawn_from, area)) : 0
                places = { held: held, held_offset: offset, scene: area || colors_scene_of(bg), tile_scene: area || tiles_scene_of(bg) }
                bg.tile_w == BIG_TILE ? @art.background_big_cell(image, **places) : @art.background_cell(image, **places)
              end
            end

            # The side of a background tile the console draws itself, beside 8×8 (BGMODE's size bits).
            BIG_TILE = 16

            # Reference#exec_scroll_background.
            def emit_scroll_background(node) = for_background(node) { |bg| emit_scroll_background_on(node, bg) }

            def emit_scroll_background_on(node, bg)
              emit_unless_put_up(node, corner_note(layer_of(bg))) do
                runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
              end
            end

            # Reference#exec_set_tile_block: its cells one by one, as its children write them.
            def emit_set_tile_block(node) = emit_children(node)

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map. A tile picked by a number known now is that tile
            # (IR::PickedTile.written).
            def emit_set_tile(node)
              if node.picked? && (number = folded(node.picked_by))
                written = PickedTile.written(node, number)
                return written && emit_set_tile(written)
              end
              for_background(node) { |bg| node.picked? ? emit_set_picked_tile_on(node, bg) : emit_set_tile_on(node, bg) }
            end

            def emit_set_tile_on(node, bg)
              return if node.tile && node.tile >= bg.tiles.length

              emit_cell_noted(node, bg) { |_outside| cell_word_of(bg, node.tile) }
            end

            # The cell at +node+'s column and row of +bg+ changed (rt_set_cell) to the word the block
            # gives back, or, where it gives back nil, the one it leaves in A; the block is handed the
            # label to jump to when the cell is to be left alone.
            def emit_cell_noted(node, bg, &word_of)
              address = written_cell_address(node, bg)
              return if address == :outside
              return emit_cell_queued_at(address, &word_of) if address
              return emit_cell_at_written_row(node, bg, &word_of) if cell_at_written_row?(node, bg)

              columns, rows = TileMap.size_of(bg.every_map.first)
              # One pair for every cell the game changes, each used only until its cell is noted: a
              # pair each ran a game of many changed cells out of memory.
              column = @cell_column ||= keep_local(:column)
              row = @cell_row ||= keep_local(:row)
              value(node.col)
              store(column)
              value(node.row)
              store(row)
              outside = fresh("cell_outside")
              emit_jump_unless_below(column, columns, outside)
              emit_jump_unless_below(row, rows, outside)
              word = yield outside
              emit_set_cell_call(layer_of(bg), column, row, word)
              @asm.label(outside)
            end

            # A cell at a column and row written in the program, as a status bar's letters are, has
            # its address in video memory known now: Runtime::Picture.cell_address, the sum
            # rt_set_cell makes as the game runs. +node+'s cell of +bg+ is that address, :outside
            # for a place off the map (the cell is left alone, as Reference#exec_set_tile leaves
            # it), or nil where the column or row is worked out as the game runs, or the row is
            # past the first 32, whose address hangs on the map put up.
            def written_cell_address(node, bg)
              column = folded(node.col)
              row = folded(node.row)
              return nil unless column && row

              columns, rows = TileMap.size_of(bg.every_map.first)
              return :outside unless (0...columns).cover?(column) && (0...rows).cover?(row)
              return nil if row >= 32

              Runtime::Picture.cell_address(layer_of(bg), column, row, third_layer: @third_layer)
            end

            # Whether +node+'s cell of +bg+ is at a row written in the program, on the map and in its
            # first 32, and a column the build proves stays from nought to 32767 (a scrolling text's
            # column the game keeps in a variable), on a map at most two screens across.
            def cell_at_written_row?(node, bg)
              row = folded(node.row)
              columns, rows = TileMap.size_of(bg.every_map.first)
              row && (0...[rows, 32].min).cover?(row) && columns <= 64 && proven_within?(node.col, 0..0x7FFF)
            end

            # A cell at a written row and a column worked out as the game runs (#cell_at_written_row?)
            # has the row's start known now (Runtime::Picture.cell_address), so only the column's low
            # half is read, held to the map's width and added, with 1024 more for a column from 32,
            # which is in the second screen across. Off the map, the cell is left alone.
            def emit_cell_at_written_row(node, bg, &word_of)
              outside = fresh("cell_outside")
              columns, = TileMap.size_of(bg.every_map.first)
              start = Runtime::Picture.cell_address(layer_of(bg), 0, folded(node.row), third_layer: @third_layer)
              emit_low_half(node.col, 16)
              unless proven_within?(node.col, 0..(columns - 1))
                @asm.cmp(columns)
                @asm.branch_long(:bcs, outside)
              end
              if columns > 32
                first_screen = fresh("cell_first_screen")
                @asm.bit(32)
                @asm.beq(first_screen)
                @asm.clc
                @asm.adc(1024 - 32)
                @asm.label(first_screen)
              end
              @asm.clc
              @asm.adc(start)
              address = place_of(@cell_column ||= keep_local(:column))
              @asm.sta(at_place(address))
              emit_cell_queued_at(at_place(address), outside: outside, &word_of)
            end

            # The cell at +address+ QUEUED for the blank, as rt_set_cell queues one, written here
            # rather than called: a cell is two words of the queue and the count, so a status bar
            # letter costs those stores, not a call that works the address out again (on the console a
            # map word goes in the blank, fullsnes "SNES PPU Video Memory", VMADD and VMDATA).
            # +address+ is a number, or where the address is kept. The block gives the word, or nil for
            # the one it leaves in A, and is handed the label to jump to when the cell is to be left
            # alone, +outside+ where one is given.
            def emit_cell_queued_at(address, outside: fresh("cell_outside"))
              room = fresh("cell_room")
              word = yield outside
              kept = Memory.register(3)
              @asm.sta(@asm.direct(kept)) unless word
              count = @asm.abs(@memory[Runtime::Picture::CELLS])
              @asm.lda(count)
              @asm.cmp(Runtime::Picture::MOST_CELLS)
              @asm.bcc(room)
              @asm.jml(@asm.long("rt_cells_full"))
              @asm.label(room)
              @asm.asl # four bytes an entry: the address, then the word
              @asm.asl
              @asm.tax
              @asm.lda(address)
              @asm.sta(@memory.indexed(@asm, Runtime::Picture::CELL_ENTRIES))
              @asm.lda(word || @asm.direct(kept))
              @asm.sta(@memory.indexed(@asm, Runtime::Picture::CELL_ENTRIES, 2))
              @asm.inc(count)
              @asm.label(outside)
            end

            # The word a cell of +bg+ showing its tile +tile+ holds in the layer's map: the tile's
            # number in video memory, its palette and whether it is in front, and nought for no tile.
            def cell_word_of(bg, tile)
              number, palette = cell_of(bg, tile)
              number ? number | (palette << Art::PALETTE_SHIFT) | (cells_in_front?(bg) ? Art::CELL_IN_FRONT : 0) : 0
            end

            # A tile picked as the game runs (Nodes::SetTile#picked_by) is a word read from a table, as
            # a console's own game writes its map: the number, less the one the list starts at, is a
            # place in a table of the words those tiles' cells hold, kept in the cartridge. A number
            # whose top half is not nought, or whose low half is past the table, is outside it (one
            # below the first is far past the last, read with no sign). A number that stands for no
            # tile reads NO_CELL, and the cell is left alone, as is a tile only another scene's
            # background of the name has. The Genesis does the same (Genesis's
            # Picture#emit_set_picked_tile_of); the halving tests IR::PickedTile writes cost a test
            # and a branch for each told number on the way to one, four times over for a cell of four tiles.
            def emit_set_picked_tile_on(node, bg)
              words = PickedTile.words(node) { |tile| cell_word_of(bg, tile) if tile < bg.tiles.length } or return

              table = @cell_tables[words] ||= "cells #{@cell_tables.length + 1}"
              emit_cell_noted(node, bg) do |outside|
                value(node.picked_by)
                unless node.picks_from.zero?
                  @asm.sec
                  @asm.lda(@asm.direct(R0))
                  @asm.sbc(node.picks_from & 0xFFFF)
                  @asm.sta(@asm.direct(R0))
                  @asm.lda(@asm.direct(R0 + 2))
                  @asm.sbc((node.picks_from >> 16) & 0xFFFF)
                  @asm.sta(@asm.direct(R0 + 2))
                end
                @asm.lda(@asm.direct(R0 + 2))
                @asm.branch_long(:bne, outside)
                @asm.lda(@asm.direct(R0))
                @asm.cmp(words.length)
                @asm.branch_long(:bcs, outside)
                @asm.asl # two bytes a word
                @asm.tax
                @asm.lda(@asm.long_x(table))
                if words.include?(PickedTile::NO_CELL)
                  @asm.cmp(PickedTile::NO_CELL)
                  @asm.branch_long(:beq, outside)
                end
                nil
              end
            end

            # A blast changes twenty cells a step, so this is written for what it is. A number from
            # nought up to +limit+ has an empty top half and a low half below the limit, and a negative
            # one has its top half full, so one test of each half stands for the two a place on a map
            # would otherwise take, each of 32 bits.
            def emit_jump_unless_below(name, limit, label)
              at = place_of(name)
              @asm.lda(at_place(at + 2))
              @asm.branch_long(:bne, label)
              @asm.lda(at_place(at))
              @asm.cmp(limit)
              @asm.branch_long(:bcs, label)
            end

            # rt_set_cell, which reads only the low half of each number: its word +word+, or the one in
            # A where that is nil.
            def emit_set_cell_call(layer, column, row, word)
              @asm.sta(@asm.direct(Memory.register(3))) unless word
              [@asm.imm(layer), at_place(place_of(column)), at_place(place_of(row)), word && @asm.imm(word)].compact.each_with_index do |from, i|
                @asm.lda(from)
                @asm.sta(@asm.direct(Memory.register(i)))
              end
              call_routine("rt_set_cell")
            end

            # Reference#exec_place_bar: a background that is not a status bar has no top to place.
            def emit_place_bar(node)
              for_background(node) do |bg|
                next unless bg.bar?

                runtime_call("rt_bar_covers", [node.covers]) if node.covers
                emit_unless_put_up(node, bar_note) { runtime_call("rt_bar_place", [Build.int(layer_of(bg)), node.top]) }
              end
            end

            # Reference#exec_box_background: the background held to the part of its box on the screen
            # (Reference#screen_box), or shown everywhere, from the next blank on
            # (Runtime::BackgroundBox's rt_background_box, which keeps the box to the screen only on a
            # pass it moved).
            def emit_box_background(node)
              for_background(node) do |bg|
                runtime_call("rt_background_box", [Build.int(layer_of(bg)), node.held, node.x, node.y, node.width, node.height])
              end
            end

            # Whether +program+ holds a background to a box (Runtime::BackgroundBox).
            def self.boxes?(program) = program.walk.any? { |node| node.kind == :box_background }

            # A scene taking over shows each background it puts up everywhere, whatever box its layer
            # held before (Reference#put_up_background), until the game holds one to a box again.
            def emit_boxes_forgotten(arrival)
              return unless Picture.boxes?(@program)

              arrival.scenery.map { |bg| layer_of(bg) }.uniq.select { |layer| LAYERS.include?(layer) }.each do |layer|
                runtime_call("rt_background_box", [Build.int(layer), *Array.new(5) { Build.int(0) }])
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

            # The layer seen through (`layer ..., transparency:`), on the console's colour math: every
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
            # A layer a scene owns, or one over a background a scene puts up, is on that scene alone,
            # and a game can have one on each of its screens, in scenes never up together. The
            # colour math is told at power-on what the first of them mixes, and each scene taking
            # over tells it again what that scene has to mix (which layers, and which are behind
            # them on the sub screen), or nothing at all on a scene with no see-through layer
            # (#emit_see_through_for_scene).
            def refuse_unmade_see_through!
              @see_through_sprites = []
              @see_through_maths = SeeThrough.layers(@program).filter_map { |layer| see_through_math_for(layer) }
              refuse_shared_see_through_screen!
              first = @see_through_maths.first
              @see_through_layers = first && [first.mixed, first.under]
            end

            # One see-through layer as the colour math shows it: +mixed+, what CGADSUB is told (the
            # layers mixed, and whether to halve and to subtract), +under+, what TS is told (the
            # layers behind it on the sub screen), and +scenes+, the numbers of the scenes it is up
            # on, or nil for a layer every screen shows alike.
            SeeThroughMath = Data.define(:layer, :mixed, :under, :scenes) do
              # CGADSUB in the low byte and TS above it, as rt_see_through_math is handed them.
              def registers_word = mixed | (under << 8)

              def sprites? = mixed.anybits?(SPRITES_BIT)
            end

            # The colour math +layer+ needs, or nil for a layer with nothing in it.
            def see_through_math_for(layer)
              refuse_unmade_moving_see_through!(layer)
              parts = Picture.see_through_parts(@program, layer, @cache.stacking)
              seen_through = parts.seen_through
              sprites = parts.sprites
              @see_through_sprites = see_through_sprites + sprites.map(&:name)
              return if seen_through.empty? && sprites.empty?
              refuse_unmade!("a see-through layer of both backgrounds and sprites") unless seen_through.empty? || sprites.empty?

              behind, scenes = see_through_behind_in_its_scenes(parts)
              # The third layer shows only above its row, where no see-through layer is on the main
              # screen (#mixed_sprites_above_row?), so it is never what is behind one.
              behind = behind.reject { |bg| on_third_layer?(bg) }
              # Adding or subtracting whole, an empty sub screen adds or takes away the fixed colour,
              # nothing: the layer whole, as the interpreter shows it over the black backdrop. Only
              # halving needs something behind.
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
              mixed |= Runtime::Picture::MATH_HALVES unless adds
              mixed |= Runtime::Picture::MATH_SUBTRACTS if layer.subtract
              SeeThroughMath.new(layer: layer, mixed: mixed, under: under, scenes: scenes)
            end

            # The console has one colour math, so a screen shows one see-through layer, and a game
            # with several needs each on scenes of its own. The build's check of that
            # (Guardrails::Checks::SeeThroughPerScreen) asks only a console that blends, so this is
            # the one that holds the Super Nintendo to it, a game with no scenes included.
            def refuse_shared_see_through_screen!
              return if @see_through_maths.length < 2

              scenes = @see_through_maths.map(&:scenes)
              return if scenes.none?(&:empty?) && scenes.flatten.uniq.length == scenes.flatten.length

              names = @see_through_maths.map { |math| ":#{math.layer.name}" }.join(" and ")
              raise LoweringError, "Layers #{names} are see-through on one screen. A Super Nintendo has one colour " \
                                   "math, so it can show one see-through layer on a screen. To fix this, put each " \
                                   "see-through layer in a scene of its own."
            end

            SeeThroughParts = Data.define(:seen_through, :sprites, :behind)

            # A sprite the game can put in and out of the see-through +layer+ (`put_in_layer`). The
            # interpreter mixes it while it is in the layer and draws it solid while it is out, and the
            # colour math reaches a sprite by the colours it is drawn with, which this build settles
            # once for each sprite.
            def refuse_unmade_moving_see_through!(layer)
              moving = @cache.stacking.objects.any? do |obj|
                layers = [obj.layer, *obj.layers].uniq
                layers.include?(layer.name) && layers.length > 1
              end
              refuse_unmade!("a sprite put in and out of a see-through layer (`put_in_layer`)") if moving
            end

            # What a see-through +layer+ is made of, and the backgrounds behind it, of every scene.
            def self.see_through_parts(program, layer, picture = Stacking.picture(program))
              scenery = picture.scenery.reject(&:bar?)
              at = picture.stack.index(layer.name)
              SeeThroughParts.new(seen_through: scenery.select { |bg| bg.layer == layer.name },
                                  sprites: picture.objects.select { |obj| obj.layer == layer.name },
                                  behind: scenery.select { |bg| bg.layer.nil? || picture.stack.index(bg.layer) < at })
            end

            # Whether +program+'s colour math changes as scenes take over: a see-through layer on some
            # scenes only, or over a background only some scenes put up, or one on each of several
            # screens.
            def self.see_through_in_scene?(program, picture = Stacking.picture(program))
              layers = SeeThrough.layers(program)
              layers.length > 1 || layers.any? { |layer| parts_in_scene?(see_through_parts(program, layer, picture)) }
            end

            # Whether a see-through layer made of +parts+ is on some scenes only, or over a background
            # only some scenes put up.
            def self.parts_in_scene?(parts)
              own = parts.seen_through + parts.sprites
              !own.empty? && (own + parts.behind).any?(&:scene)
            end

            # The backgrounds behind a see-through layer made of +parts+ on the scenes that show it,
            # one lot, and the numbers of those scenes: nil for a layer every screen shows alike, in a
            # game whose colour math never changes.
            def see_through_behind_in_its_scenes(parts)
              return [parts.behind, nil] unless Picture.see_through_in_scene?(@program, @cache.stacking)
              # Several layers in a game with no scenes are on its one screen together, up on no scene
              # of their own (#refuse_shared_see_through_screen!).
              return [parts.behind, []] if @scenes.empty?

              own = parts.seen_through + parts.sprites
              names = own.filter_map(&:scene).uniq
              showing = names.empty? ? @scenes.keys : names
              lots = showing.map { |scene| parts.behind.select { |bg| bg.scene.nil? || bg.scene == scene } }
              unless lots.map { |lot| lot.map { |bg| layer_of(bg) }.sort }.uniq.one?
                refuse_unmade!("a see-through layer over backgrounds on different layers in different scenes")
              end
              [lots.first, showing.map { |scene| @scenes.fetch(scene) }]
            end

            # Whether the colour math changes as scenes take over (#see_through_behind_in_its_scenes).
            def see_through_by_scene? = see_through_maths.any?(&:scenes)

            def see_through_maths = @see_through_maths || []

            # A scene taking over: the colour math told what this scene has to mix, its layer's
            # amount as the game left it, or nothing at all on a scene with no see-through layer.
            def emit_see_through_for_scene(scene)
              return unless see_through_by_scene?

              number = @scenes.fetch(scene)
              math = see_through_maths.find { |candidate| candidate.scenes.include?(number) }
              runtime_call("rt_see_through_math", [math ? see_through_math_now(math) : Build.int(0)])
            end

            # What the colour math is to be told for the amount +math+'s layer stands at now.
            def see_through_math_now(math)
              on = Build.binop(:!=, math.layer.behind.copy, Build.int(0))
              Build.binop(:*, on, Build.int(math.registers_word))
            end

            # Whether +layer+ shows the whole of itself over the whole of what is behind it, which the
            # console's colour math does with no halving, adding what is behind or taking it away. What
            # is behind may be a number the game works out, for a layer it turns solid: that is the one
            # amount it can change, and it is 100 or 0 (#emit_see_through_amount).
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

            # Whether +program+ turns a see-through layer solid as it runs, or changes its colour math
            # as scenes take over, which the runtime then keeps what the colour math is told in
            # (Runtime::Picture's rt_see_through_math).
            def self.see_through_turns_solid?(program, picture = Stacking.picture(program))
              SeeThrough.layers(program).any? { |layer| !layer.split && layer.behind.kind != :int } ||
                see_through_in_scene?(program, picture)
            end

            # Reference#exec_see_through: the colour math on while what is behind shows, and off, the
            # layer solid, at nought. An amount between shows as 100 does: the console adds or it does
            # not. It is told in the next blank, with the frame's sprites. A layer whose amounts are
            # numbers is told nothing here: the framework puts the step in for every see-through layer
            # of a game with several, and each scene taking over has told the math already.
            def emit_see_through_amount(node)
              math = see_through_maths.find { |candidate| candidate.layer.name == node.layer }
              return if math.nil? || SeeThrough.fixed?(math.layer)
              return emit_see_through_amount_while_up(math) if math.scenes

              runtime_call("rt_see_through_math", [see_through_math_now(math)])
            end

            # ...and on a layer some scenes show, only while one of them is up: the next to take
            # over tells the math again.
            def emit_see_through_amount_while_up(math)
              past = fresh("see_through_away")
              up = fresh("see_through_up")
              math.scenes.each do |number|
                other = fresh("see_through_not_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
                @asm.brl(up)
                @asm.label(other)
              end
              @asm.brl(past)
              @asm.label(up)
              runtime_call("rt_see_through_math", [see_through_math_now(math)])
              @asm.label(past)
            end

            # The sprites' bit of the colour math's registers (TS, CGADSUB).
            SPRITES_BIT = 0x10

            # The names of the sprites in a see-through layer, drawn from the palettes the colour
            # math reaches (Art#split_sprite_palettes!).
            def see_through_sprites = @see_through_sprites || []

            # The scenes no see-through layer of sprites is on, whose colour math reaches no sprite
            # while they are up (#emit_see_through_for_scene); none for a game whose colour math
            # never changes.
            def scenes_without_see_through
              return [] unless see_through_by_scene?

              mixing = see_through_maths.select(&:sprites?).flat_map(&:scenes)
              @scenes.keys.reject { |scene| mixing.include?(@scenes.fetch(scene)) }
            end

            # Half of the layer and half of what is behind, which the colour math makes by halving the
            # sum or the difference.
            HALF = [SeeThrough::STEPS / 2, SeeThrough::STEPS / 2].freeze

            # The amounts of the game's see-through layers, asked before the kinds a Super Nintendo
            # cannot do (Lowering#refuse_what_snes_lacks!), so the framework's step that tells the
            # console an amount again (`:see_through`, put in for an amount worked out as the game
            # runs) is refused in words about the amount. A game can have one on each of its
            # screens (#refuse_unmade_see_through!).
            def refuse_see_through_amounts!
              SeeThrough.layers(@program).each { |layer| refuse_see_through_amount!(layer) }
            end

            def refuse_see_through_amount!(layer)
              return if added_to_what_is_behind?(layer)

              worked_out = [layer.shows, layer.behind].any? { |amount| amount.kind != :int }
              raise LoweringError, SEE_THROUGH_WORKED_OUT if worked_out
              return if SeeThrough.weights(layer, layer.shows.value, layer.behind.value).map(&:abs) == HALF

              said = layer.split ? "`transparency: #{layer.behind.value}`" : "`shows: #{layer.shows.value}, shows_behind: #{layer.behind.value}`"
              said += ", `subtract: true`" if layer.subtract
              raise LoweringError, "Layer :#{layer.name} is see-through by #{said}. A Super Nintendo can show a layer " \
                                   "half see-through only: `transparency:` from 50 to 56, or `shows: 50, shows_behind: " \
                                   "50`. It can also add a layer to what is behind it: `shows: 100, shows_behind: 100`. " \
                                   "With `subtract: true`, it takes what is behind away by the same amounts. " \
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

              image = @cache.image(picture_named(bg.tiles.fetch(tile)))
              (0...64).none? { |at| image.tile_see_through_at?(at) }
            end

            # --- a background bent row by row ---

            # Reference#exec_scroll_rows: a standing declaration, gathered up front (#bends). Its rows
            # are worked out at every frame boundary (#emit_bends), not where it is written.
            def emit_scroll_rows(_node) = nil

            # The game's bends: the last each background is given, in the order the backgrounds were
            # first bent (RowBends).
            def bends = @plan.row_bends.bends

            # Reference#work_out_bends, before the pass's wait, in the order every lowering works bends
            # out in (BendSchedule): each row of the screen, its number in the bend's variable, the
            # bend's own steps, and how far along the row sits kept in the layer's rows
            # (Runtime::Picture.bend_offsets) for the frame the wait shows.
            #
            # A game all of whose bends hold one value for whole bands of rows has each band worked
            # out once (#bend_bands_taken). All of them or none: a block asked every row can change a
            # number another block reads, and then that one's rows are not bands at all.
            #
            # A bend whose scene is away is asked as it is on the interpreter if its block can change
            # a number the game reads (RowBends#observable_while_away?), and otherwise takes none of the frame.
            # Only the rows of one whose scene is up are kept: a layer has one set of rows, and
            # another scene's bend may share the layer.
            def emit_bends = emit_bends_worked_out

            def bend_screen_height = Runtime::Picture::SCREEN_HEIGHT

            # A block asked once a band rather than once a row (BendSchedule::OWN_WAYS).
            def bend_bands_taken(bend) = @plan.row_bends.bands(bend, Runtime::Picture::SCREEN_HEIGHT)

            # Rows +first+ to +past+ - 1 of +bend+, left out while its scene is away if the game cannot
            # tell. The variable ends at +past+, or at the row for a single row.
            def emit_bend_rows(bend, first, past)
              last = past - first == 1 ? first : past
              emit_bend_rows_unless_away(bend, last) { emit_bend_row_loop(bend, first, past) }
            end

            # A bend's bands, as steps of lines where every bend's fit the runtime's room for them
            # (#bends_by_bands?), and as every row's offset otherwise.
            def emit_bend_bands(bend, firsts)
              height = Runtime::Picture::SCREEN_HEIGHT
              emit_bend_rows_unless_away(bend, height) do
                bends_by_bands? ? emit_bend_steps(bend, firsts) : emit_bend_band_rows(bend, firsts)
              end
            end

            # Each way of working a bend out leaves its row variable at the height already.
            def emit_row_variable_set(_bend, _height) = nil

            # Each bend's bands, as the first row of each, or nil for a bend asked every row.
            def bend_bands
              @bend_bands ||= bends.map { |bend| @plan.row_bends.bands(bend, Runtime::Picture::SCREEN_HEIGHT) }
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
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend.node)))]
              at = offsets
              firsts.zip(band_steps(firsts)).each do |first, steps|
                statement(Build.set(bend.row, first))
                bend.body.each { |child| statement(child) }
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
            def emit_bend_band_rows(bend, firsts)
              height = Runtime::Picture::SCREEN_HEIGHT
              firsts.zip(firsts.drop(1) + [height]).each do |first, past|
                statement(Build.set(bend.row, first))
                bend.body.each { |child| statement(child) }
                emit_band_offset(bend, first...past)
              end
              statement(Build.set(bend.row, height))
            end

            def emit_band_offset(bend, rows)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend.node)))]
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
                @asm.lda(at_place(place_of(@scene)))
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
              bg = background_declared_for(bend.node)
              return nil if scenery_holds?(@handover.always_up.scenery, bg)

              @scenes.filter_map { |scene, number| number if scenery_holds?(@handover.arrival(scene).scenery, bg) }
            end

            def scenery_holds?(scenery, bg) = scenery.any? { |up| up.equal?(bg) }

            # The block's rows, left out while the bend's scene is away if the game cannot tell
            # (RowBends#observable_while_away?). The row's variable still ends at +last_row+, as the
            # rows would have left it.
            def emit_bend_rows_unless_away(bend, last_row, &rows)
              return yield if scenes_showing(bend).nil? || @plan.row_bends.observable_while_away?(bend)

              emit_while_bend_up(bend, &rows)
              statement(Build.set(bend.row, last_row))
            end

            # Keeps a row's offset only while the bend's scene is up, in a bend whose block ran
            # whichever scene is up. One left out while away (#emit_bend_rows_unless_away) has no need.
            def emit_row_store_while_up(bend, &store)
              @plan.row_bends.observable_while_away?(bend) ? emit_while_bend_up(bend, &store) : yield
            end

            # Rows +first+ to +past+ - 1 of +bend+, leaving its variable at +past+, or at the row for
            # a single row.
            def emit_bend_row_loop(bend, first, past)
              top = fresh("bend_row")
              done = fresh("bend_rows_done")
              statement(Build.set(bend.row, first))
              @asm.label(top)
              bend.body.each { |child| statement(child) }
              emit_bend_offset(bend)
              return if past - first == 1

              statement(Build.add(bend.row, 1))
              jump_unless(Build.binop(:<, Build.var_ref(bend.row), Build.int(past)), done)
              @asm.brl(top)
              @asm.label(done)
            end

            # The row in the bend's variable kept at its place in the layer's rows: the low 16 bits of
            # how far along, all the console's scroll register takes.
            def emit_bend_offset(bend)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend.node)))]
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
              refuse_unmade!("a status bar bent row by row") if bends.any? { |bend| background_declared_for(bend.node)&.bar? }
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays
            # where it was.
            def emit_show_map(node) = for_background(node) { |bg| emit_show_map_on(node, bg) }

            # A background's map handed over replaces the cells the game changed on it in the same pass
            # (Reference#exec_show_map keeps no cell changed before it), so the cells queued for the
            # blank to copy after the map are taken out. A status bar's map is not replaced so: it
            # happens where the game says it, and a cell set after it shows over it. A background no
            # line sets a cell of has none queued, so its map change calls nothing. The cells of other
            # layers stay (Runtime::Picture#emit_cells_drop).
            def drop_queued_cells(bg)
              return if bg.bar? || !@set_tiles_by_name.key?(bg.name)

              @cells_dropped = true
              runtime_call("rt_cells_drop", [Build.int(Runtime::Picture.cell_address(layer_of(bg), 0, 0, third_layer: @third_layer))])
            end

            def emit_show_map_on(node, bg)
              which = keep_local(:map)
              value(node.which)
              store(which)
              done = fresh("map_shown")
              bg.every_map.each_index do |number|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(number)), other)
                emit_area_up(bg, area_key(bg, bg.map_sets.fetch(number))) if bg.several_sets?
                runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, number).number), Build.int(0)])
                drop_queued_cells(bg)
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
                Stacking.items_in_draw_order(node).each do |item|
                  next emit_ordered_run(item) if item.is_a?(Build::DrawOrder)

                  emit_sprite_placing(object_named(item), item)
                end
              end
              @asm.label(done)
            end

            def object_named(name) = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }

            # One sprite placed, if it is showing, as deep as the name +at+ — its own, or one of the other
            # layers it can be put in (Stacking.choice_name) — has it among the backgrounds.
            # +shown_known+ for one its draw order's sort already found showing on this pass
            # (ShownSort#found_showing_by_sort), which is not asked again.
            def emit_sprite_placing(obj, at = obj.name, shown_known: false)
              skip = fresh("sprite_off")
              jump_unless(Build.binop(:==, obj.active, Build.int(1)), skip) unless shown_known
              behind = sprite_depths.empty? ? [] : [Build.int((3 - sprite_depths.fetch(at, 3)) << SPRITE_PRIORITY_SHIFT)]
              emit_sprite_place(obj, obj.name, behind)
              @asm.label(skip)
            end

            # A run the game puts in order as it runs (Reference#names_in_draw_order): its list holds the
            # run's sprites back to front, each by its place in the run, so each entry in turn places
            # the sprite it names — back-most first, as every sprite here is. +depths+ is the names of
            # the depth being placed, by sprite, for a frame with sprites that change layer; a sprite
            # not named has no place at that depth.
            #
            # Each entry is doubled into X, and JSR (table,X) jumps to the entry's stub in a table of
            # them written here: the sprite's placing itself, written out once for the run, and an
            # RTS. Five instructions an entry however long the run, where comparing the entry with
            # each place in turn would grow with the square of the run. The table is in this routine's
            # own code, so in its bank, which is where JSR (table,X) reads it. A sprite with no place
            # at this depth has a stub that only returns.
            #
            # The framework's own list (Build::DrawOrder#permutation) holds every place of the run in
            # its slots, so each entry is read straight from its slot with nothing tested. Any other
            # list — one written by hand, or one something takes items from the front of, whose slots
            # move round — is walked as the interpreter reads it (DrawOrderWalk), through the same table.
            #
            # The placing is in the stub rather than a routine the stub calls: the JSL there and the
            # RTL back were two of the seven instructions an ordered sprite cost beyond its placing.
            def emit_ordered_run(run, depths = nil)
              _place, _capacity, width = @lists.fetch(run.order) do
                raise LoweringError, "the list #{run.order.inspect} orders sprites and is never declared"
              end
              table = fresh("ordered_stubs")
              stubs = run.objects.map { fresh("ordered_stub") }
              placing = fresh("ordered_placing")
              found = order_read_by_slots?(run, front_dropped_lists) ? found_showing_by_sort(run) : []
              @asm.brl(placing)
              @asm.label(table)
              @asm.data_words(stubs)
              run.objects.each_with_index do |name, at|
                @asm.label(stubs[at])
                emit_ordered_sprite_placing(name, depths, shown_known: found.include?(name)) unless depths && !depths.key?(name)
                @asm.rts
              end
              @asm.label(placing)
              return emit_ordered_run_walked(run, table) unless order_read_by_slots?(run, front_dropped_lists)

              keyed = @keyed_sorts&.fetch(run.order, nil)
              # A sorted run keeps its things not showing in its first places (ShownSort), so it starts
              # past them, through a table of where each entry's placing starts.
              shown = @shown_sorts&.fetch(run.order, nil)
              steps = run.objects.each_index.map { fresh("ordered_step") } + [fresh("ordered_steps_done")]
              if shown
                steps_table = fresh("ordered_steps")
                @asm.ldx(@asm.abs(shown.hidden))
                @asm.branch_long(:beq, steps.first)
                @asm.jmp(@asm.ind_abs_x(steps_table))
                @asm.label(steps_table)
                @asm.data_words(steps)
              end
              run.objects.each_index do |k|
                @asm.label(steps[k])
                if keyed
                  # A sorted order keeps its items doubled in the first 8K as well (Lowering#emit_keyed_sort).
                  @asm.ldx(@asm.abs(keyed.entries + (k * 2)))
                else
                  @asm.lda(@asm.long(list_slots(run.order).at(k)))
                  @asm.and_a(0x00FF) if width == 1
                  @asm.asl
                  @asm.tax
                end
                @asm.jsr(@asm.ind_abs_x(table))
              end
              @asm.label(steps.last)
            end

            # A run whose list is walked as the interpreter reads it (DrawOrderWalk), each entry's
            # place doubled into X for JSR (table,X), as the run read a slot an entry does.
            def emit_ordered_run_walked(run, table)
              emit_draw_order_walk(run) do |place|
                @asm.lda(at_place(place_of(place)))
                @asm.asl
                @asm.tax
                @asm.jsr(@asm.ind_abs_x(table))
              end
            end

            # DrawOrderWalk's: the place the variable +name+ holds and the run's +count+, the fault's two
            # numbers, and no list, as the interpreter words it (Faults.draw_order_names_none).
            def emit_draw_order_fault(name, count)
              fault = @memory[Runtime::Frame::FAULT]
              entry = place_of(name)
              @asm.stz(@asm.abs(fault + Runtime::Frame::FAULT_LIST))
              @asm.stz(@asm.abs(fault + Runtime::Frame::FAULT_LIST + 2))
              @asm.lda(at_place(entry))
              @asm.sta(@asm.abs(fault + Runtime::Frame::FAULT_FIRST))
              @asm.lda(at_place(entry + 2))
              @asm.sta(@asm.abs(fault + Runtime::Frame::FAULT_FIRST + 2))
              @asm.lda(count)
              @asm.sta(@asm.abs(fault + Runtime::Frame::FAULT_SECOND))
              @asm.stz(@asm.abs(fault + Runtime::Frame::FAULT_SECOND + 2))
              @asm.lda(Runtime::Frame::DRAW_ORDER_NAMES_NONE)
              @asm.jml(@asm.long("rt_fault"))
            end

            # Sprite +name+ of an ordered run placed, or placed when it is at the depth +depths+ names
            # for it. +shown_known+ for one the sort found showing on this pass.
            def emit_ordered_sprite_placing(name, depths, shown_known: false)
              return emit_sprite_placing(object_named(name), shown_known: shown_known) unless depths

              emit_sprite_placed_at(object_named(name), depths.fetch(name), @cache.stacking.depths)
            end

            # A frame with sprites that change layer as the game runs (`put_in_layer`,
            # Reference#object_level): every depth any of them can be at, back-most first, and at each,
            # every sprite that can be there, placed when the layer it is in now is that one — so a
            # sprite is placed once, among the sprites of its layer now, behind the backgrounds as
            # that layer is. A run the game orders is walked at each depth, for those of its sprites
            # that are there, so the order holds inside each layer.
            def emit_layer_changing_sprites(node, objects)
              depths = @cache.stacking.depths
              depth_of = ->(obj, level) { depth_names(obj).find { |name| depths[name] == level } }
              objects.flat_map { |obj| Stacking.levels_of(depths, obj) }.uniq.sort.each do |level|
                Stacking.items_in_draw_order(node).each do |item|
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

            # Reference#exec_fade and #exec_tint, as a walk of the colours (IR::Fading walks every fade
            # on a console that cannot blend; PaletteWalk says what the walk is and when it is done,
            # Runtime::Tint does it here). rt_tint holds the steps to their range itself (PaletteWalk
            # says why), so they are handed over unheld.
            def emit_fade(node) = emit_palette_walk(node)
            def emit_tint(node) = emit_palette_walk(node)

            def emit_palette_walk(node)
              walk = PaletteWalk.walk_for(node)
              runtime_call("rt_tint", [Build.int(walk.toward), Build.int(walk.color), walk.unheld_steps])
            end

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
