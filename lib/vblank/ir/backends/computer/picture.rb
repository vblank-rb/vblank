# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE PICTURE, written as C: the drawing statements, a scene taking the screen over, and
        # the art they draw with. Mixed into Lowering, beside the logic.
        #
        # The drawing itself is done by runtime/rg_screen.c, a port of the interpreter's picture;
        # what this half does is lay it out in the interpreter's order and hand over the art. All of
        # the art is worked out HERE, in Ruby, with the interpreter's own readings of it — which
        # pixel of a tile shows what is behind, which color a pixel of a picture is — so the C
        # never has a second opinion about a pixel.
        module Picture
          # The kinds of screen, as rg_screen.h numbers them.
          SCREEN_KINDS = Ractor.make_shareable({ bitmap: 0, tiled: 1, rotozoom: 2 })

          # rg_screen.h's own numbers: whose a background is (RG_EVERY_SCENE, RG_NEVER_ARRIVES),
          # a background that named no layer, a pixel of a sprite's picture that is not drawn,
          # a cell of a map with no tile, and how many backgrounds and sprites there is room for.
          EVERY_SCENE = -1
          NEVER_ARRIVES = -2
          NO_LAYER = -1
          # A background that is not a status bar, and a status bar's level (RG_NOT_A_BAR).
          NOT_A_BAR = -1
          NOT_DRAWN = -1
          # The most a drawn pixel can be: fifteen bits of colour, so a picture's pixels fit in
          # sixteen signed bits beside NOT_DRAWN.
          MAX_COLOR = 0x7FFF
          CELL_EMPTY = -1
          # How many numbers describe one map (RG_MAP_FIELDS): where its cells start, its columns, its
          # rows, and the columns and rows of the grid it comes round at.
          MAP_FIELDS = 5
          MAX_BACKGROUNDS = 64
          MAX_SPRITES = 512
          # A thing in no see-through layer (RG_SOLID), and how many of those layers there is
          # room for (RG_MAX_SEE_THROUGH).
          SOLID = -1
          MAX_SEE_THROUGH = 16

          # The kinds the interpreter's picture is rebuilt whole every frame for (see
          # Reference#collect_definitions and #run, and #rebuilt_every_frame? for the rest of the
          # rule).
          REBUILT_FOR = %i[tile_run scroll_background place_bar box_background scroll_rows affine_background set_tile show_map
                           show_held_tiles background_colors pixelate].freeze

          # A sprite the game leaves as drawn whatever size the picture's blocks are (RG_NOT_IN_BLOCKS).
          NOT_IN_BLOCKS = -1
          # A tile that is a picture and not one the game paints, and a background with no
          # painted tile (RG_NOT_PAINTED).
          NOT_PAINTED = -1
          # How many places a run's colors have: a painted pixel is four bits.
          PLACES_IN_RUN_COLORS = 16
          # A painted tile's side, and how many pixels that makes (Reference::RUN_TILE_BYTES is
          # half of them, two pixels to a byte).
          RUN_TILE_SIDE = 8
          RUN_TILE_PIXELS = RUN_TILE_SIDE * RUN_TILE_SIDE

          private

          def prepare_picture
            @stacking = Stacking.picture(@program)
            @handover = SceneHandover.of(@program)
            @fading = Fading.resolve(@program)
            # A background's name -> the entry that keeps what the game does to it. That is the
            # last one declared by the name, in the order the program declares them, as the
            # interpreter's @bg_by_name keeps it; the stack's order can differ once layers are named.
            @last_declared = @program.walk.select { |node| node.kind == :background }.to_h { |bg| [bg.name, bg] }
            @backgrounds = @last_declared.transform_values { |bg| entry_of(bg) }
            @objects = by_name(@program.walk, :object)
            @sprites = @objects.each_key.with_index.to_h # sprite name -> the number rg_screen.c knows it by
            @drawn_sprites = DrawnSprites.new(@program) # the names a run gives its sprites by
            @left_out_of_blocks = names_left_out_of_blocks
            @bar_in_blocks = Blocks.bar_in_blocks!(@program, LoweringError)
            # The runs of tiles and the pictures the game paints from lists as it runs, and the
            # number rg_screen.c knows each by.
            @tile_runs = by_name(@program.walk, :tile_run)
            # A pose drawn from sprite tiles the game loads is a painted picture here too: its
            # pixels are kept as places, and a load writes the tiles it changes into each pose
            # that draws them (rg_tile_pose_load).
            @sprite_tile_sets = by_name(@program.walk, :sprite_tiles)
            @tile_poses = by_name(@program.walk, :tile_pose)
            @tile_poses.each_value { |pose| @tile_runs[pose.name] = pose_run(pose) }
            @run_numbers = @tile_runs.each_key.with_index.to_h
            # The lists of sprite colors that hold other colors as the game runs.
            @color_lists = by_name(@program.walk, :color_list)
            # The layers the game can be seen through, and the number rg_screen.c knows each by.
            @see_through = SeeThrough.layers(@program)
            @see_through_numbers = @see_through.each_with_index.to_h { |layer, number| [layer.name, number] }
            # By name, the furthest forward anything of that name was declared (see #fade_place).
            @fade_places = (@stacking.scenery + @stacking.objects).group_by(&:name).transform_values do |named|
              named.filter_map { |thing| @stacking.stack.index(thing.layer) }.max || NO_LAYER
            end
            # The patches of picture saved under sprites on a painted screen, as the program
            # declared them, and the number rg_screen.c knows each by.
            @patches = by_name(@program.walk, :backing_buffer)
            @patch_numbers = @patches.each_key.with_index.to_h
            @images = {} # [picture name, the list of colors it is drawn with or nil] -> its number in rg_game_images
            @drawing_arrays = [] # constant arrays the drawing statements need, written before the routines
            refuse_unsupported_picture!
          end

          # --- what this backend cannot draw yet, refused before anything is written ---

          def refuse_unsupported_picture!
            refuse_picture!("more than #{MAX_SEE_THROUGH} see-through layers") if @see_through.size > MAX_SEE_THROUGH
            refuse_picture!("more than #{MAX_BACKGROUNDS} backgrounds") if @stacking.scenery.length > MAX_BACKGROUNDS
            refuse_picture!("more than #{MAX_SPRITES} sprites") if @sprites.size > MAX_SPRITES
          end

          # Reference#place_blocks: where this program's blocks stop. A program that pixelates
          # gets one place for them, and one that names two is refused in the words every backend
          # refuses it in. What comes back is the names of everything in the layer its statements
          # are placed under and in front of it, which stay as drawn whatever the size; no names
          # for a program that pixelates the whole picture; and nil for one that never pixelates.
          def names_left_out_of_blocks
            places = Blocks.places(@program)
            raise LoweringError, Blocks.several_places_message(places) if places.size > 1
            return nil if places.empty?

            places.first ? Stacking.at_or_above(@stacking, places.first).map(&:name) : []
          end

          # Reference#in_blocks?, all of it but the size: is this background or sprite drawn in
          # blocks while the picture is shown in them? By its name, as the interpreter asks.
          def shown_in_blocks?(thing) = !@left_out_of_blocks.nil? && !@left_out_of_blocks.include?(thing.name)

          # ...and for a background, which a status bar is only where the program puts its bar in
          # blocks too (Reference#paint_status_bar).
          def background_in_blocks?(bg)
            shown_in_blocks?(bg) && (!bg.bar? || @bar_in_blocks)
          end

          def refuse_picture!(what)
            raise LoweringError, "this program uses #{what}, which #{build_name} cannot draw yet. " \
                                 "The cartridge build can."
          end

          def constant?(node, value) = node.kind == :int && node.value == value

          # Reference#collect_definitions and #run: whether the whole view is rebuilt every
          # frame — for scenery that can look different next frame, a fade placed in the stack,
          # what is seen through a layer changing while nothing moves, or scenery a named layer
          # puts in front of a sprite — rather than sprites drawn straight onto a picture that
          # stays.
          def rebuilt_every_frame?
            @program.walk.any? { |node| REBUILT_FOR.include?(node.kind) || (node.kind == :fade && node.under) } ||
              see_through_picture_changes? ||
              Stacking.scenery_over_objects?(@stacking.depths, scenery: @stacking.scenery, objects: @stacking.objects)
          end

          # Reference#see_through_picture_changes?: an amount the game works out, or a fade the
          # display itself does, which holds a see-through layer solid for as long as it is on.
          def see_through_picture_changes?
            return false if @see_through.empty?

            @program.walk.any? do |node|
              node.kind == :see_through || (node.kind == :fade && !@fading.palette_walk?(node))
            end
          end

          # --- the art, for rg_screen.c ---

          def picture_data
            [*image_arrays, *background_arrays, *see_through_arrays, sprite_fade_places_array, *sprite_block_arrays,
             *run_arrays, image_pieces_array,
             runtime_array("picture_sizes", "int32_t",
                    [@stacking.scenery.length, @stacking.depths.count, @handover.always_up.scenery.length,
                     rebuilt_every_frame? ? 1 : 0, @see_through.size,
                     Modes.resolve(@program).crosses_display_systems? ? 1 : 0, Blocks::LARGEST,
                     @tile_runs.size, @tile_runs.each_value.sum { |run| run_pixels(run) }, @images.size,
                     sprites_over_picture? ? 1 : 0]),
             runtime_array("always_up", "int32_t", @handover.always_up.scenery.map { |bg| entry_of(bg) }),
             runtime_array("sines", "int32_t", (0...450).map { |degrees| Affine.sine(degrees) }),
             runtime_array("turn_rules", "int32_t", [Build::SCALE_ONE, Affine::ONE_TH, Affine::MAX, Affine::MIN_SCALE])]
          end

          # An array of numbers rg_screen.c reads by name (rg_game_ and +what+).
          # +writable+ is for one the routine that reads the start file writes into.
          def runtime_array(what, type, values, writable: false)
            Statements::ConstArray.new(name: @names.own(what), type: type, values: values, exported: true, writable: writable)
          end

          # Every picture a sprite can show, once for each list of colors it is drawn with. A pixel
          # is fifteen bits of colour or -1 for see-through, so sixteen signed bits hold it: a
          # game's pictures are most of its program, and four bytes a pixel doubled them.
          def image_arrays
            pixels = []
            info = []
            @images.each_key do |name, colors|
              image = picture_named(name)
              info.push(pixels.length, image.width, image.height)
              from_start_file = picture_from_start_file(name)
              record_start_file_fill(:image, pixels.length, from_start_file, colors) if from_start_file
              drawn = if colors == SHADING_PLACES
                        bitmap = @data.fetch(name)
                        bitmap.places_in_shading(bitmap.shading)
                      else
                        sprite_pixels(image, colors)
                      end
              if drawn.any? { |pixel| pixel > MAX_COLOR && !IR::StartFile.marker?(pixel) }
                raise LoweringError, "picture #{name.inspect} holds a pixel past the fifteen bits a colour has, " \
                                     "so #{build_name} cannot make it."
              end
              # A pixel in a colour read as the game starts is its marker until then (StartFileFills).
              record_marked_pixels(:image, pixels.length, drawn)
              pixels.concat(drawn.map { |pixel| image_pixel_kept(pixel) })
            end
            @image_pixel_count = pixels.length # what the runtime copies them by, to fill an image read from the start file
            [runtime_array("image_pixels", "int16_t", pixels), runtime_array("images", "int32_t", info), *sprite_name_arrays]
          end

          # Reference#sprites names each sprite it drew by two names: the one the game declared it
          # under, and the one the author gave the picture it shows, whatever colors that is
          # drawn in. So each sprite and each picture has the number of its name (DrawnSprites),
          # for a run to report what it drew.
          def sprite_name_arrays
            [runtime_array("sprite_names", "int32_t", @objects.each_value.map { |obj| @drawn_sprites.name_number(obj.declared) }),
             runtime_array("image_pictures", "int32_t", @images.each_key.map { |name, _| @drawn_sprites.picture_number(name) })]
          end

          # For every sprite, where the boxes it is put into blocks by start, or NOT_IN_BLOCKS for
          # one the game leaves as drawn, every one of them in a game that pixelates its
          # backgrounds alone (Reference#sprite_in_blocks?); and the boxes themselves (see
          # rg_screen.h for the layout).
          def sprite_block_arrays
            boxes = []
            keeps_sprites = Blocks.keeps_sprites?(@program, LoweringError)
            starts = @objects.each_value.map do |obj|
              next NOT_IN_BLOCKS if keeps_sprites || !shown_in_blocks?(obj)

              boxes.length.tap { boxes.concat(boxes_by_picture(obj)) }
            end
            [runtime_array("sprite_blocks", "int32_t", starts), runtime_array("sprite_boxes", "int32_t", boxes)]
          end

          # Reference#paint_object_in_blocks and #object_boxes: one sprite's pictures, each with
          # the boxes a console draws it as, which is the cut every backend asks SpriteCut for. A
          # sprite that turns or resizes is put into blocks whole and lists none. The interpreter
          # finds a pose's boxes by the first place its picture has among the sprite's poses, so
          # a picture is listed once.
          def boxes_by_picture(obj)
            return [0] if turns_or_resizes?(obj)

            width, height = sprite_canvas(obj)
            whole = obj.poses.any? { |pose| painted_picture?(pose) }
            cut = SpriteCut.new(sprite_pictures).cut(obj.poses, width: width, height: height, whole: whole)[:boxes]
            pictures = obj.poses.uniq
            [pictures.length, *pictures.flat_map do |pose|
              boxes = cut.fetch(obj.poses.index(pose))
              [@drawn_sprites.picture_number(pose), boxes.length, *boxes.flatten]
            end]
          end

          # Reference#sprite_piece_places, for a console that draws only so many pieces of sprites on
          # a line: how tall a piece is, then where each image's pieces start, then each image's
          # pieces (see rg_screen.h for the layout). Only how tall a piece is where the console
          # draws them all.
          def image_pieces_array
            console = @program.described_console
            tall = (@program.sprite_piece_size_on(console.name) || [SpritePieces::SIZE] * 2).last
            values = [tall]
            if console.sprite_pieces_drawn_a_line
              lists = @images.each_key.map { |name, _| sprite_piece_places(name, tall) }
              start = 1 + lists.length
              lists.each do |places|
                values << start
                start += 1 + (2 * places.length)
              end
              lists.each { |places| values.push(places.length, *places.flatten) }
            end
            runtime_array("image_pieces", "int32_t", values)
          end

          # Where the pieces of the picture +name+ stand in it, as the console's table holds them.
          def sprite_piece_places(name, tall)
            return SpriteLines.tile_pose_places(@tile_poses.fetch(name).pieces, piece_height: tall) if @tile_poses.key?(name)

            run = @tile_runs.each_value.find { |r| r.picture == name }
            return SpriteLines.painted_places(run.width, run.height, piece_height: tall) if run

            SpriteLines.picture_places(sprite_pictures.fetch(name), piece_height: tall)
          end

          # Every picture the program defines, as SpriteCut reads one.
          def sprite_pictures
            @sprite_pictures ||= @data.select { |_, node| node.kind == :bitmap }.transform_values { |node| Assets::Image.of(node) }
          end

          # Reference#painted_picture?: is this picture one the game paints from a list as it runs?
          def painted_picture?(name) = @tile_runs.each_value.any? { |run| run.picture == name }

          # A pose drawn from a set of sprite tiles, as the fields of a painted picture's run.
          PoseRun = Data.define(:name, :picture, :width, :height, :colors, :colors_name) do
            def tiles = []
            def console_format = false
            def squares_per_tile = 1
          end

          def pose_run(pose)
            set = @sprite_tile_sets.fetch(pose.tiles)
            PoseRun.new(name: pose.name, picture: pose.name, width: pose.width, height: pose.height, colors: set.colors,
                        colors_name: set.colors_name)
          end

          # Reference#exec_load_sprite_tiles: each number worked out once, the load checked against
          # the ends of the table and the set (LoweringPlan.sprite_tile_load_bounds), then each pose
          # drawn from the set takes the tiles of the load it draws, and the picture is built again.
          def lower_load_sprite_tiles(node)
            set = @sprite_tile_sets.fetch(node.name)
            table = @tables.fetch(node.table)
            bounds = LoweringPlan.sprite_tile_load_bounds(node, table_bytes: table.entry_count, set_count: set.count)
            return [] unless bounds

            from, to = %w[load_from load_to].map { |what| local_name(what) }
            fits = [from, to].zip(bounds).map do |name, (_, most)|
              call("rg_both", call("rg_ge", name, Statements::Int.new(0)), call("rg_le", name, Statements::Int.new(most)))
            end.reduce { |both, each| call("rg_both", both, each) }
            kept = Lowering::TABLE_KEPT_AS.fetch(table_type(table))
            loads = @tile_poses.each_value.select { |pose| pose.tiles == node.name }.map do |pose|
              pieces = drawing_array("pose_pieces", "int32_t", pose.pieces.flatten)
              eval_call("rg_tile_pose_load", Statements::Int.new(@run_numbers.fetch(pose.name)), pieces, Statements::Int.new(pose.pieces.length),
                        @names.of(:table, node.table), Statements::Int.new(kept), from, to, Statements::Int.new(node.count))
            end
            [Statements::Block.new([Statements::Local.new(name: from, value: value(node.at)), Statements::Local.new(name: to, value: value(node.to)),
                           Statements::If.new(condition: fits, body: [*loads, eval_call("rg_screen_request_rebuild")], otherwise: [])])]
          end

          # A sprite picture's pixels as the interpreter draws them (Reference#blit_image): the
          # number the picture stores, the color +colors+ puts in its place when the sprite is
          # drawn with that list (Assets::Recolor), or NOT_DRAWN where it is see-through.
          def sprite_pixels(image, colors)
            recolor = colors && Assets::Recolor.of(image, colors)
            Array.new(image.width * image.height) do |at|
              next NOT_DRAWN unless image.drawn_at?(at)

              recolor ? recolor.color_for(at, image.raw_at(at)) : image.raw_at(at)
            end
          end

          # A picture the game paints from a list is see-through all over until its first copy
          # (Reference#collect_definitions), which is the picture written into the game for it.
          # The box every one of a sprite's pictures fits in (SpriteCut.canvas_of), a picture the
          # game paints included.
          def sprite_canvas(obj) = SpriteCut.canvas_of(obj.poses.to_h { |pose| [pose, picture_named(pose)] }, obj.poses)

          def picture_named(name)
            painted = @tile_runs.each_value.find { |run| run.picture == name }
            return painted_image(painted, Array.new(run_pixels(painted), 0), width: painted.width, height: painted.height) if painted

            Assets::Image.of(@data.fetch(name) { raise LoweringError, "a sprite shows the picture #{name.inspect}, which is not defined" })
          end

          # --- tiles and pictures the game paints from a list (Reference#copy_run_tiles) ---

          # How many pixels a run keeps: its picture's, or its tiles'.
          def run_pixels(run) = run.picture ? run.width * run.height : run.tiles.length * run.squares_per_tile * RUN_TILE_PIXELS

          # Reference#run_picture_from_places: a painted picture as everything that draws one
          # reads it, +places+ being each pixel's place in the run's colors. It keeps the run's
          # list as its own, which is how a swap of colors finds it.
          def painted_image(run, places, width:, height:)
            pixels = places.map { |place| place.zero? ? Graphics::Image::TRANSPARENT : run.colors.fetch(place, 0) }
            Assets::Image.new(width: width, height: height, transparent: Graphics::Image::TRANSPARENT,
                              pixels: pixels.pack("v*"), colors: run.colors, places: places.pack("C*"),
                              colors_name: run.colors_name)
          end

          # A strip with one pixel at each place a run's colors have. What a painted pixel shows
          # depends on its place and nothing else, so reading this strip the way a tile or a
          # sprite's picture is read gives the color of every place at once, by the same rules
          # as art that was drawn ahead of time.
          def every_place_of(run) = painted_image(run, (0...PLACES_IN_RUN_COLORS).to_a, width: PLACES_IN_RUN_COLORS, height: 1)

          # The run that paints the tile +name+, or nil for a tile that is a picture.
          def run_painting(name) = @tile_runs.each_value.find { |run| run.tiles.include?(name) }

          # Each run as rg_screen.h's fields, and for each run that is a sprite's picture the
          # images that are that picture, one for each list of colors it is drawn with, with the
          # color each place shows in it (#sprite_pixels, asked of every place at once).
          def run_arrays
            pixels = 0
            images = []
            runs = @tile_runs.each_value.flat_map do |run|
              start = pixels
              pixels += run_pixels(run)
              planes = run.console_format ? @program.described_console.tile_planes.to_i : 0
              next [run.tiles.length * run.squares_per_tile, 0, 0, start, 0, 0, planes] unless run.picture

              first = images.length / (PLACES_IN_RUN_COLORS + 1)
              shown_as = @images.select { |(name, _), _| name == run.picture }
              shown_as.each do |(_, colors), number|
                shown = sprite_pixels(every_place_of(run), colors)
                # A place in a colour read as the game starts is its marker until then (StartFileFills).
                record_marked_numbers(:run_images, images.length + 1, shown)
                images.push(number, *shown)
              end
              [0, run.width, run.height, start, first, shown_as.size, planes]
            end
            [runtime_array("tile_runs", "int32_t", runs),
             runtime_array("run_images", "int32_t", images, writable: marked_numbers_in?(:run_images))]
          end

          # Reference#exec_copy_tiles and what a scene arriving does with each run it shows.
          def tile_copy(run)
            eval_call("rg_tiles_copy", Statements::Int.new(@run_numbers.fetch(run.name)), Statements::AddressOf.new(list(run.list)))
          end

          def lower_copy_tiles(node)
            [tile_copy(@tile_runs.fetch(node.name)), eval_call("rg_screen_request_rebuild")]
          end

          # Reference#exec_copy_owed_tiles: every run whose bit is set in the game's own
          # variables, in the order the statement lists them, and then the rebuild whether any
          # was or not.
          def lower_copy_owed_tiles(node)
            per = Nodes::CopyOwedTiles::RUNS_PER_MASK
            copies = node.runs.each_with_index.map do |name, i|
              bit = call("rg_and", call("rg_shr", variable(node.masks.fetch(i / per)), Statements::Int.new(i % per)), Statements::Int.new(1))
              Statements::If.new(condition: call("rg_eq", bit, Statements::Int.new(1)), body: [tile_copy(@tile_runs.fetch(name))])
            end
            [*copies, eval_call("rg_screen_request_rebuild")]
          end

          # Every background in the order the stack draws them, its tiles as colors with
          # RG_SEE_THROUGH where the layer behind shows (Reference#tile_colors), and every map
          # it can show, the one it starts with first. A background that can be drawn from other
          # lists of colors has its tiles written again for each step it can be told, after the
          # ones in the colors they were drawn in.
          def background_arrays
            tile_pixels = []
            cells = []
            maps = []
            painted_tiles = []
            run_colors = []
            fields = @stacking.scenery.flat_map do |bg|
              tiles_start = tile_pixels.length
              steps = color_swaps(bg)
              # A background whose map is read from the start file has, after the tiles the game
              # holds for it, a tile for every cell of the map, see-through until the file is read
              # (StartFileFills#record_start_file_background_fill).
              cell_tiles = bg.from_file ? bg.from_file.tiles_drawn : 0
              tile_count = bg.tiles.length + cell_tiles
              record_start_file_background_fill(tiles_start, bg, steps) if bg.from_file
              [nil, *steps].each do |swaps|
                bg.tiles.each do |tile|
                  if (read_at_start = picture_from_start_file(tile))
                    record_start_file_fill(:tile, tile_pixels.length, read_at_start, swaps && swaps[Assets::Image.of(read_at_start).list_drawn_from])
                  end
                  drawn = tile_colors(tile, swaps)
                  record_marked_pixels(:tile, tile_pixels.length, drawn)
                  tile_pixels.concat(drawn)
                end
                tile_pixels.concat(Array.new(cell_tiles * RUN_TILE_PIXELS, 0xFFFF))
              end
              painted_start, colors_start = painted_tiles_of(bg, steps, painted_tiles, run_colors)
              first_map = maps.length / MAP_FIELDS
              bg.every_map.each do |map|
                # A background that never comes round again has no grid to come round at.
                maps.push(cells.length, *TileMap.size_of(map), *(bg.streams? ? [0, 0] : TileMap.grid(map)))
                # Read from the start file, each cell names its own tile, in order, after the tiles
                # the game holds.
                cells.concat(bg.from_file ? (bg.tiles.length...tile_count).to_a : map_cells(map))
              end
              [bg.tile_w, bg.tile_h, first_map, Array(bg.maps).length, @backgrounds.fetch(bg.name),
               bg.streams? ? 1 : 0, tiles_start,
               bg.scene ? @scenes.fetch(bg.scene, NEVER_ARRIVES) : EVERY_SCENE, bg.bar? ? NOT_A_BAR : @stacking.depths.of_scenery(bg),
               @handover.on_arrival?(bg) ? 1 : 0, stack_place(bg.layer),
               see_through_number(bg), @bends.key?(bg.name) ? 1 : 0, fade_place(bg),
               tile_count, steps.length, background_in_blocks?(bg) ? 1 : 0, bg.affine ? 1 : 0,
               painted_start, colors_start, bg.bar_top || NOT_A_BAR, bg.above_row || NOT_A_BAR]
            end
            @tile_pixel_count = tile_pixels.length # what the runtime copies them by, to fill a tile read from the start file
            [runtime_array("tile_pixels", "uint16_t", tile_pixels), runtime_array("backgrounds", "int32_t", fields),
             runtime_array("maps", "int32_t", maps), runtime_array("map_cells", "int16_t", cells),
             runtime_array("painted_tiles", "int32_t", painted_tiles, writable: paints_moving_cells?),
             runtime_array("run_colors", "uint16_t", run_colors, writable: marked_numbers_in?(:run_colors))]
          end

          # A background's tiles the game paints, added to the two arrays rg_screen.c finds them
          # by, and where each of its two parts starts there; NOT_PAINTED twice for a background
          # with none. First, for each of its tiles, the run that paints it and which of the
          # run's tiles it is. Then the color each place of each run shows on this background,
          # in the colors its tiles were drawn in and again for each step it can be told
          # (Reference#tile_colors, asked of every place at once).
          def painted_tiles_of(bg, steps, painted_tiles, run_colors)
            runs = bg.tiles.map { |tile| run_painting(tile) }
            return [NOT_PAINTED, NOT_PAINTED] if runs.none?

            starts = [painted_tiles.length, run_colors.length]
            bg.tiles.zip(runs) do |tile, run|
              painted_tiles.concat(run ? [@run_numbers.fetch(run.name), run.tiles.index(tile)] : [NOT_PAINTED, 0])
            end
            # A background read from the start file whose tiles take turns through pictures has
            # a tile for every cell after the ones the game holds, none painted until the routine
            # reading the file points the cells naming such a tile at a run's (StartFileFills).
            if bg.from_file && !bg.from_file.moving.empty?
              record_start_file_moving_cells(bg, starts.first)
              painted_tiles.concat(Array.new(bg.from_file.tiles_drawn * 2) { |at| at.even? ? NOT_PAINTED : 0 })
            end
            [nil, *steps].each do |swaps|
              @tile_runs.each_value do |run|
                shown = colors_as_tile(every_place_of(run), swaps)
                record_marked_numbers(:run_colors, run_colors.length, shown)
                run_colors.concat(shown)
              end
            end
            starts
          end

          # Each see-through layer as rg_screen.h's three flags (Reference#fixed_see_through?,
          # SeeThroughLayer#split, and the half of Reference#layer_has_anything? that asks
          # about sprites), and for every sprite the see-through layer it was declared in.
          def see_through_arrays
            flags = @see_through.flat_map do |layer|
              [layer.shows.kind == :int && layer.behind.kind == :int, layer.split,
               @objects.each_value.any? { |obj| obj.layer == layer.name }].map { |flag| flag ? 1 : 0 }
            end
            [runtime_array("see_through", "int32_t", flags),
             runtime_array("sprite_see_through", "int32_t", @objects.each_value.map { |obj| see_through_number(obj) })]
          end

          # For every sprite, whether a fade placed in the stack reaches it (see #fade_place).
          def sprite_fade_places_array
            runtime_array("sprite_fade_places", "int32_t", @objects.each_value.map { |obj| fade_place(obj) })
          end

          # How far forward a layer is among the layers the game declared, or NO_LAYER for a name
          # that is none of them, and for a thing that named no layer.
          def stack_place(layer) = @stacking.stack.index(layer) || NO_LAYER

          # IR::Stacking.at_or_above, asked of one thing ahead of time: the furthest forward a
          # placed fade's layer can be and still leave +thing+ as drawn, or NO_LAYER when every
          # placed fade reaches it.
          #
          # The interpreter takes the NAMES of everything declared in the fade's layer or in
          # front of it, scenery and sprites in one list, and leaves a thing as drawn when its
          # name is among them (Reference#set_blend_for). So two things with one name are left or
          # reached together, by whichever of them was declared further forward, and that is the
          # place given here.
          def fade_place(thing) = @fade_places.fetch(thing.name, NO_LAYER)

          # Reference#see_through_layer_of: the see-through layer a background or a sprite was
          # declared in, by its number, or SOLID. The interpreter asks by name, and a name is
          # first the last background declared by it, so two backgrounds of one name, or a sprite
          # named like a background, are both drawn as that background's layer is.
          def see_through_number(thing)
            @see_through_numbers.fetch(@last_declared.fetch(thing.name, thing).layer, SOLID)
          end

          # The routine rg_screen.c calls for a see-through layer's two amounts as they are now
          # (Reference#live_see_through_weights), answering for the layer it is asked about.
          def see_through_amounts
            answers = @see_through.each_with_index.map do |layer, number|
              Statements::If.new(condition: call("rg_see_through_asked", Statements::Int.new(number)),
                        body: [eval_call("rg_see_through_answer", value(layer.shows), value(layer.behind))])
            end
            Statements::Function.new(name: @names.own("see_through_amounts"), body: answers, exported: true)
          end

          # Reference#exec_see_through
          def lower_see_through(node)
            [eval_call("rg_see_through_told", Statements::Int.new(@see_through_numbers.fetch(node.layer)))]
          end

          # The routine rg_screen.c calls for how far across one row of a bent background sits
          # (Reference#run_bend_for_row), answering for the background it is asked about: the row
          # goes into the bend's variable, what its block asks to run runs, and the offset is
          # worked out from there.
          def bend_offsets
            answers = @bends.each_value.map do |bend|
              Statements::If.new(condition: call("rg_bend_asked", Statements::Int.new(@backgrounds.fetch(bend.name))),
                        body: [assign(bend.row, call("rg_bend_line")), *body_of(bend),
                               eval_call("rg_bend_answer", value(bend.offset))])
            end
            Statements::Function.new(name: @names.own("bend_offsets"), body: answers, exported: true)
          end

          # Reference#work_out_bends: every bend's line 0, then the rest of each bend in turn,
          # which leaves each bend's row one past the bottom of the screen, the program's console's.
          # Called last in every frame boundary (rg_screen_work_out_bends).
          def work_out_bends
            height = @program.described_console.screen_height
            first_lines = @bends.each_key.map { |name| work_out_bend_lines(name, 0, 1) }
            the_rest = @bends.flat_map do |name, bend|
              [work_out_bend_lines(name, 1, height), assign(bend.row, Statements::Int.new(height))]
            end
            Statements::Function.new(name: @names.own("work_out_bends"), body: first_lines + the_rest, exported: true)
          end

          # The routines rg_screen.c calls to work the game's light out (Reference#work_out_shade):
          # where the lit span of one row starts and ends, the row going into the light's
          # variable first, and then how dark the rest of every row goes, or for a light that
          # shows nothing outside it, whether it is on. Empty for a game with no light, which
          # never calls them.
          def shade_span
            body = if @shade
                     [assign(@shade.row, call("rg_shade_line")), *body_of(@shade),
                      eval_call("rg_shade_left", value(@shade.left)),
                      eval_call("rg_shade_right", value(@shade.right))]
                   else
                     []
                   end
            Statements::Function.new(name: @names.own("shade_span"), body: body, exported: true)
          end

          def shade_amount
            amount_call = @shade&.shuts_out ? "rg_shade_shut_out" : "rg_shade_darkness"
            body = @shade ? [eval_call(amount_call, value(@shade.amount))] : []
            Statements::Function.new(name: @names.own("shade_amount"), body: body, exported: true)
          end

          def work_out_bend_lines(name, first, past)
            eval_call("rg_bend_work_out", Statements::Int.new(@backgrounds.fetch(name)), Statements::Int.new(first), Statements::Int.new(past))
          end

          # Reference#exec_scroll_rows: the bend stands from power-on, so where it is written
          # only asks for the picture to be built again — which is what shows the bend in a game
          # that never waits for the screen, whose lines are worked out as they are painted.
          def lower_scroll_rows(_node) = [eval_call("rg_screen_request_rebuild")]

          # A map's cells, row after row: the number of the tile, or CELL_EMPTY where the map
          # has none. A map is a rectangle (the builder refuses any other).
          def map_cells(map)
            cols, = TileMap.size_of(map)
            map.flat_map { |row| Array.new(cols) { |col| row[col] || CELL_EMPTY } }
          end

          # Reference#background_swap, for every step a background can be told: each of the lists
          # its tiles were drawn from, to the list that step draws it with instead, or to nil
          # where that list stays as drawn.
          def color_swaps(bg)
            return followed_color_swaps(bg) if bg.follows_several?

            Array(bg.recolors).each_index.map { |step| bg.list_swaps(step) }
          end

          # A BACKGROUND THAT FOLLOWS SEVERAL LISTS THE GAME CHANGES (Background#follows_each) has its
          # tiles written again for every set each of those lists can hold, list after list, the set
          # a list was declared with first, and every other list as declared in each. No set is a
          # pair of two lists' sets, which would be one list's sets times the other's. The picture is
          # drawn from the tiles as declared, and when a list is told what to hold, the tiles drawn
          # from it alone are copied over those from the set it names (#followed_tile_copies).
          def followed_color_swaps(bg)
            (@followed_color_swaps ||= {})[bg.object_id] ||= begin
              declared = bg.lists_followed.to_h { |list| [list, sets_held_by(list).first] }
              bg.lists_followed.flat_map do |list|
                sets_held_by(list).map { |set| bg.followed_list_swaps(declared.merge(list => set)) }
              end
            end
          end

          # Reference#followed_background_swap, for the list +name+: on each background that follows
          # it beside other lists, the tiles drawn from it are copied from the set it holds now.
          # The rules rg_background_follow reads are how many tile pixels the game has, the
          # background's entry, how many of its tiles are drawn from the list, and those tiles.
          #
          # Written where the list is told what to hold, and again where a state is read
          # (Lowering#visit_state).
          def followed_tile_copies(name)
            (@lists_copied_to_followers ||= []) << name
            @stacking.scenery.select { |bg| bg.lists_followed.include?(name) }.filter_map do |bg|
              rules = followed_tile_rules(bg, name) or next
              first = 1 + bg.lists_followed.take_while { |list| list != name }.sum { |list| sets_held_by(list).length }
              held = call("rg_place_of_choice", held_colors(name), Statements::Int.new(sets_held_by(name).length - 1))
              eval_call("rg_background_follow", rules, call("rg_add", Statements::Int.new(first), held))
            end
          end

          # The copies of every list a statement of the game tells what to hold, made again: their
          # rules are written already, so this adds no array after the arrays are written out.
          def followed_tile_copies_again = (@lists_copied_to_followers || []).uniq.flat_map { |name| followed_tile_copies(name) }

          # The rules for one background and one list it follows, made once, or nil where none of
          # its tiles is drawn from the list.
          #
          # A BACKGROUND READ FROM THE START FILE has a tile for every cell of its map after the
          # tiles the game holds, and which bank a cell is of is in the file. So its rules are
          # written with room for every one of those tiles, where the routine reading the file can
          # write, and that routine adds the tiles of the cells whose bank is drawn from the list
          # (StartFileFills#record_start_file_followed_tiles).
          def followed_tile_rules(bg, name)
            (@followed_tile_rules ||= {})[[bg.object_id, name]] ||= begin
              tiles = bg.tiles.each_index.select { |at| bg.list_followed_by(tile_image(bg.tiles[at]).list_drawn_from) == name }
              rules = [tile_pixel_total, entry_of(bg), tiles.length, *tiles]
              if bg.from_file
                record_start_file_followed_tiles(bg, tiles, rules)
              else
                tiles.empty? ? :none : drawing_array("followed_tiles", "int32_t", rules)
              end
            end
            @followed_tile_rules[[bg.object_id, name]].then { |rules| rules == :none ? nil : rules }
          end

          # How many pixels the tiles of every background take, each written once for the colors it
          # was drawn in and once for each step (#background_arrays).
          def tile_pixel_total
            @stacking.scenery.sum do |bg|
              tiles = bg.tiles.sum { |tile| tile_image(tile).then { |image| image.width * image.height } }
              tiles += bg.from_file.tiles_drawn * RUN_TILE_PIXELS if bg.from_file
              tiles * (color_swaps(bg).length + 1)
            end
          end

          # Reference#tile_colors: a tile's pixels as colors, or as the colors +swaps+ gives the
          # list it was drawn from. A swap goes by place, and is read off the pixel as drawn, so
          # what is see-through stays see-through whatever the other list holds there.
          def tile_colors(name, swaps = nil) = colors_as_tile(tile_image(name), swaps)

          # A tile's picture. One the game paints is see-through all over until its first copy
          # (Reference#blank_run_tile), and that is what is written into the game for it: the C
          # reads what was painted in its place.
          def tile_image(name)
            run = run_painting(name)
            return Assets::Image.of(@data.fetch(name)) unless run

            painted_image(run, Array.new(run.tile_side * run.tile_side, 0), width: run.tile_side, height: run.tile_side)
          end

          def colors_as_tile(image, swaps)
            swapped = swaps && swaps[image.list_drawn_from]
            recolor = swapped && Assets::Recolor.of(image, swapped)
            Array.new(image.width * image.height) do |i|
              next 0xFFFF if image.tile_see_through_at?(i)

              recolor ? recolor.color_for(i, tile_color_at(image, i)) : tile_color_at(image, i)
            end
          end

          # The colour a tile's pixel is drawn in: its fifteen bits, or, for a pixel in a colour
          # read as the game starts, the marker it is (IR::StartFile), which those bits are no part of.
          def tile_color_at(image, index)
            raw = image.raw_at(index)
            IR::StartFile.marker?(raw) ? raw : image.color_at(index)
          end

          # The number of the picture +name+ as drawn with the list +colors+, or with its own.
          def image_number(name, colors = nil) = @images[[name, colors]] ||= @images.size

          # --- the drawing statements ---

          # A tear-free screen is two pages. The list of colors one can be given changes nothing
          # that is drawn: a color is still named, and the build has already refused one the
          # list does not hold.
          # The colour shown wherever nothing is drawn goes with it (IR::SceneHandover#backdrop_of).
          def lower_screen(node) = screen_change("rg_screen_set", node.mode, node.buffered, @handover.backdrop_of(node))

          # A change of screen, by `screen` or by a scene arriving on its own. The C decides when
          # that put the scenery every screen shows up again as declared, and what sets which
          # map each of those backgrounds shows then goes back to the first, and what every
          # screen shows that the game paints is copied in from its list as it is now, as
          # Reference#put_up_always_up does both. A tear-free screen is two pages only on a console
          # that has two to paint (Console::Description#painted_pages); on one that has one, it is
          # the one, as the interpreter has it.
          def screen_change(function, screen, two_pages, backdrop)
            two_pages &&= @program.described_console.painted_pages == 2
            # A backdrop that follows a list (nil) is left as the list has it, which rg_screen.c reads
            # as a colour below nought. One read from the start file is its entry of the colours
            # filled from it (StartFileFills#start_file_color), and so is the colour of a list read
            # from it, which is a marker here.
            shown = backdrop.is_a?(IR::StartFile::Color) ? start_file_color(backdrop) : color_or_start_file_entry(backdrop || -1)
            change = call(function, Statements::Int.new(SCREEN_KINDS.fetch(screen)), yes_or_no(two_pages), shown)
            always = @handover.always_up
            put_back = [*always.map_choices.map { |var| assign(var, Statements::Int.new(0)) },
                        *(always.painted_tiles + always.painted_pictures).map { |run| tile_copy(run) }]
            return [Statements::Eval.new(change)] if put_back.empty?

            [Statements::If.new(condition: change, body: put_back)]
          end

          def lower_clear_screen(node) = [eval_call("rg_screen_clear", color(node.color))]

          # Reference#exec_inside: the edges are numbers written in the program.
          def lower_inside(node)
            [eval_call("rg_screen_inside", *[node.x, node.y, node.w, node.h].map { |edge| Statements::Int.new(edge) }),
             *body_of(node), eval_call("rg_screen_inside_ended")]
          end

          def lower_camera(node) = [eval_call("rg_screen_camera", value(node.x), value(node.y))]

          def lower_blit(node)
            [eval_call("rg_screen_blit", Statements::Int.new(image_number(node.name)), value(node.x), value(node.y))]
          end

          def lower_blit_pose(node)
            pictures = drawing_array("poses", "int32_t", node.poses.map { |name| image_number(name) })
            [eval_call("rg_screen_blit_pose", pictures, Statements::Int.new(node.poses.length), value(node.index),
                       value(node.x), value(node.y))]
          end

          def lower_draw_column_at(node)
            [eval_call("rg_screen_column", Statements::Int.new(image_number(node.name)), value(node.slice), value(node.x),
                       value(node.top), value(node.height), Statements::Int.new(node.width || 1))]
          end

          # Reference#exec_draw_place: the statements under it, which hand the place's routine the
          # viewer and the view and call it.
          def lower_draw_place(node) = body_of(node)

          # Reference#exec_fill_face: the pictures it picks from and which, the list of corners and
          # how many, then the edges nothing outside is drawn.
          def lower_fill_face(node)
            pictures = drawing_array("pictures", "int32_t", node.pictures.map { |name| image_number(name) })
            [eval_call("rg_screen_face", pictures, Statements::Int.new(node.pictures.length), value(node.picture),
                       Statements::AddressOf.new(list(node.corners)), value(node.count),
                       *node.edges.map { |operand| value(operand) }, value(node.perspective), shading_array(node))]
          end

          # A lit fill's shading as the runtime reads it: how many levels, how many colours, the
          # colours, then each level's places (Nodes::Shading), then for each of the fill's pictures
          # the image of its numbers into the shading's colours (Nodes::Bitmap#places_in_shading),
          # or -1 for a picture of colours; a fill that is not lit hands the one number nought.
          def shading_array(node)
            shading = node.shading && @shadings.fetch(node.shading)
            values = if shading
                       numbered = node.pictures.map do |name|
                         picture = @data[name]
                         picture&.kind == :bitmap && picture.places_in_shading(node.shading) ? image_number(name, SHADING_PLACES) : -1
                       end
                       [shading.levels.length, shading.colors.length, *shading.colors, *shading.levels.flatten, *numbered]
                     else
                       [0]
                     end
            return drawing_array("shading", "int32_t", values) unless shading&.from_file

            array = drawing_array("shading", "int32_t", values, writable: true)
            record_start_file_shading_fill(array, shading)
            array
          end

          # The key, in place of a list of colours, of an image whose pixels are a picture's numbers
          # into its shading's colours (#shading_array).
          SHADING_PLACES = :shading_places

          def lower_save_region(node) = [patch_statement("rg_patch_save", node)]
          def lower_restore_region(node) = [patch_statement("rg_patch_restore", node)]

          # Reference#backing_for: a patch is kept in the buffer the program declared for it,
          # which sets how big it is.
          def patch_statement(function, node)
            buffer = @patches.fetch(node.buffer) do
              raise LoweringError, "backing buffer #{node.buffer.inspect} is used and never declared"
            end
            eval_call(function, Statements::Int.new(@patch_numbers.fetch(node.buffer)), Statements::Int.new(buffer.width),
                      Statements::Int.new(buffer.height), value(node.x), value(node.y))
          end

          def lower_fill_rect(node)
            [eval_call("rg_screen_fill_rect", *[node.x, node.y, node.w, node.h].map { |n| value(n) }, color(node.color))]
          end

          alias lower_dma_fill_rect lower_fill_rect
          alias lower_draw_rect_at lower_fill_rect

          def lower_pixel(node) = [eval_call("rg_screen_pixel", value(node.x), value(node.y), color(node.color))]

          # The pixels of a line of text are known when the game is built, so they are handed
          # over as points rather than worked out from the font as it runs.
          def lower_draw_text(node)
            points = node.fonts.get(node.font).enum_for(:each_pixel, node.text).flat_map { |dx, dy| [dx, dy] }
            name = drawing_array("text_points", "int16_t", points)
            ink = node.picked ? call("rg_pick_color", value(node.showing), color(node.color), color(node.picked)) : color(node.color)
            [eval_call("rg_screen_points", value(node.x), value(node.y), ink, name, Statements::Int.new(points.length / 2))]
          end

          # A live digit: the ten digits' points, and where each begins.
          def lower_draw_digit(node)
            font = node.fonts.get(node.font)
            per_digit = (0..9).map { |d| font.enum_for(:each_pixel, d.to_s).flat_map { |dx, dy| [dx, dy] } }
            starts = per_digit.each_with_object([0]) { |points, at| at << (at.last + (points.length / 2)) }
            [eval_call("rg_screen_digit", value(node.value), value(node.x), value(node.y), color(node.color),
                       drawing_array("digit_points", "int16_t", per_digit.flatten), drawing_array("digit_starts", "int32_t", starts))]
          end

          # Reference#exec_background: a scene's own scenery on a screen drawn from tiles goes up
          # as the scene arrives, not here; any other is put up (or, inside a scene, stamped into
          # the picture like any drawing) each time this runs.
          def lower_background(node)
            return [] if @handover.on_arrival?(node)

            id = Statements::Int.new(entry_of(node))
            [eval_call("rg_screen_paint_owed_rebuild"), eval_call(node.scene ? "rg_background_stamp" : "rg_background_put_up", id)]
          end

          # Reference#exec_place_bar
          def lower_place_bar(node)
            return [] if @stacking.scenery.none? { |bg| bg.name == node.name && bg.bar? } # no top to place

            covers = node.covers && eval_call("rg_bar_covers", background_number(node), value(node.covers))
            [covers, eval_call("rg_place_bar", background_number(node), value(node.top))].compact
          end

          # Reference#exec_box_background
          def lower_box_background(node)
            [eval_call("rg_background_box", background_number(node), value(node.x), value(node.y),
                       value(node.width), value(node.height), value(node.held))]
          end

          def lower_scroll_background(node)
            [eval_call("rg_background_scroll", background_number(node), value(node.x), value(node.y))]
          end

          # A tile picked as the program runs is written as the tests it stands for (IR::PickedTile):
          # the runtimes take a tile's number, and keep no table of a background's cells to index.
          def lower_set_tile(node)
            if node.picked?
              tests = PickedTile.tests(node)
              return tests ? lower(tests) : []
            end
            if node.held
              return [eval_call("rg_background_hold_tile", background_number(node), value(node.col), value(node.row),
                                Statements::Int.new(node.tile), Statements::Int.new(Nodes::ShowHeldTiles::MOST_CELLS))]
            end

            [eval_call("rg_background_set_tile", background_number(node), value(node.col), value(node.row),
                       Statements::Int.new(node.tile))]
          end

          # Reference#exec_show_held_tiles
          def lower_show_held_tiles(_node) = [eval_call("rg_show_held_tiles")]

          def lower_show_map(node) = [eval_call("rg_background_show_map", background_number(node), value(node.which))]

          # Reference#exec_background_colors
          def lower_background_colors(node)
            [eval_call("rg_background_draw_with", background_number(node), value(node.which))]
          end

          # The number rg_screen.c knows the background a statement names by: the entry that
          # keeps what the game does to that name (see #entry_of for one declaration's own).
          def background_number(node)
            Statements::Int.new(@backgrounds.fetch(node.name) do
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}"
            end)
          end

          # Reference#exec_affine_background: a map whose named point sits at the pivot is first
          # moved that far from the screen's corner, as a scroll, which the turn is worked out over.
          def lower_affine_background(node)
            turn = eval_call("rg_background_turn", background_number(node), value(node.angle),
                             value(node.scale), Statements::Int.new(node.around_x), Statements::Int.new(node.around_y))
            return [turn] if node.map_shift == [0, 0]

            [eval_call("rg_background_scroll", background_number(node), *node.map_shift.map { |pixels| Statements::Int.new(pixels) }),
             turn]
          end

          # Reference#exec_present_objects: every sprite the frame draws is taken off the picture,
          # then each one that is shown is put where it is now.
          #
          # A frame the game asked to draw without sprites takes them all off and puts none back,
          # and forgets it was asked (Reference#exec_hide_sprites).
          def lower_present_objects(node)
            drawn = node.names.map { |name| presented_object(name) }
            placements = placements_in_draw_order(node)
            if hides_sprites?
              placements = [Statements::If.new(condition: sprites_hidden, body: [Statements::Assign.new(sprites_hidden, Statements::Int.new(0))],
                                      otherwise: placements)]
            end
            [eval_call("rg_objects_begin"), *drawn.map { |obj| sprite_removal(obj) },
             *placements, eval_call("rg_objects_end")]
          end

          # Does the game show sprites over a painted screen (`sprite ..., over_picture: true`)?
          def sprites_over_picture? = IR::SpritesOverPicture.any?(@program)

          # Reference#advance_frame: the routine the runtime calls as a two-page screen publishes
          # the page just finished, placing the sprites over the picture from the numbers then, as
          # the frame's own placing does after the wait. Empty in a game without such sprites.
          def sprites_over_picture_routine
            present = sprites_over_picture? && IR::SpritesOverPicture.frame_sprite_step(@program)
            Statements::Function.new(name: @names.own("sprites_over_picture"), body: present ? lower_present_objects(present) : [],
                            exported: true)
          end

          # Reference#exec_hide_sprites: noted, for the frame drawn after this pass.
          def lower_hide_sprites(_node) = [Statements::Assign.new(sprites_hidden, Statements::Int.new(1))]

          def hides_sprites? = (@hides_sprites ||= [@program.walk.any? { |node| node.kind == :hide_sprites }]).first

          def sprites_hidden = @names.own("sprites_hidden")

          def sprites_hidden_globals = hides_sprites? ? [Statements::Global.new(name: sprites_hidden)] : []

          def presented_object(name)
            @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }
          end

          # Reference#names_in_draw_order: the frame's sprites placed as listed, except that each
          # run the game puts in order is placed in the order its list holds now. A run stands
          # where its first sprite is listed and takes the place of as many names as it has.
          def placements_in_draw_order(node)
            runs = Array(node.orders)
            runs.each { |run| refuse_scattered_run!(node, run) }
            refuse_sprite_in_two_runs!(runs)
            starts = runs.to_h { |run| [run.objects.first, run] }
            inside_a_run = runs.flat_map(&:objects)
            node.names.flat_map do |name|
              next [ordered_run_placement(starts.fetch(name))] if starts.key?(name)
              next [] if inside_a_run.include?(name)

              [sprite_placement(presented_object(name))]
            end
          end

          # The interpreter swaps a run in by position: as many names as the run has, from where
          # its first is listed, and one run after another. In every program the builder makes
          # those names are the run's own sprites and no sprite is in two runs, and only then is
          # placing each run's sprites by name, as the C below does, the same thing. So a tree
          # that is not like that is refused, by this and by #refuse_sprite_in_two_runs!.
          def refuse_scattered_run!(node, run)
            first = node.names.index(run.objects.first)
            return if first && node.names[first, run.objects.length] == run.objects

            raise LoweringError, "a run of sprites drawn in a worked-out order (#{run.order.inspect}) is not " \
                                 "side by side in the frame's draw list"
          end

          def refuse_sprite_in_two_runs!(runs)
            shared, = runs.flat_map(&:objects).tally.find { |_, times| times > 1 }
            return unless shared

            raise LoweringError, "sprite #{shared.inspect} is in two runs drawn in a worked-out order"
          end

          # One run: for each place the order list holds, back to front, the sprite it names is
          # placed.
          def ordered_run_placement(run)
            order = Statements::AddressOf.new(list(run.order))
            count = local_name("count")
            index = local_name("index")
            place = local_name("place")
            placed = run.objects.each_with_index.map do |name, at|
              Statements::If.new(condition: call("rg_eq", place, Statements::Int.new(at)), body: [sprite_placement(presented_object(name))])
            end
            read_place = call("rg_place_in_ordered_run", call("rg_list_get", order, index), Statements::Int.new(run.objects.length))
            Statements::Block.new([Statements::Local.new(name: count, value: call("rg_list_length", order)),
                          Statements::Local.new(name: index, value: Statements::Int.new(0)),
                          Statements::While.new(condition: call("rg_lt", index, count),
                                       body: [Statements::Local.new(name: place, value: read_place), *placed,
                                              Statements::Assign.new(index, call("rg_add", index, Statements::Int.new(1)))])])
          end

          # A sprite covered the box all its pictures fit in (Reference#restore_scene_rect).
          # One that turns or resizes, whose pictures are one size, covered more, and how much
          # more depends on whether its size ever changes.
          def sprite_removal(obj)
            unless turns_or_resizes?(obj)
              width, height = sprite_canvas(obj)
              return eval_call("rg_object_take_off", sprite_number(obj), Statements::Int.new(width), Statements::Int.new(height))
            end

            eval_call("rg_object_take_off_turned", sprite_number(obj), Statements::Int.new(image_number(obj.poses.first)),
                      yes_or_no(!constant?(obj.scale, Build::SCALE_ONE)))
          end

          # Reference#objects_on_screen: a sprite is drawn when it is switched on and its pose
          # names one of its pictures.
          def sprite_placement(obj)
            pose = local_name("pose")
            in_range = call("rg_both", call("rg_ge", pose, Statements::Int.new(0)), call("rg_lt", pose, Statements::Int.new(obj.poses.length)))
            placed = [sprite_number(obj), picture_drawn(obj, pose), value(obj.x), value(obj.y), level_drawn_at(obj)]
            add = if turns_or_resizes?(obj)
                    eval_call("rg_objects_add_turned", *placed, value(obj.angle), value(obj.scale),
                              yes_or_no(!constant?(obj.scale, Build::SCALE_ONE)))
                  else
                    eval_call("rg_objects_add", *placed)
                  end
            Statements::If.new(condition: call("rg_eq", value(obj.active), Statements::Int.new(1)),
                      body: [Statements::Block.new([Statements::Local.new(name: pose, value: value(obj.pose)),
                                           Statements::If.new(condition: in_range, body: [add])])])
          end

          # Reference#object_transformed?: a sprite turns or resizes unless both its angle and
          # its size are still the numbers every sprite starts with.
          def turns_or_resizes?(obj) = !(constant?(obj.angle, 0) && constant?(obj.scale, Build::SCALE_ONE))

          def sprite_number(obj) = Statements::Int.new(@sprites.fetch(obj.name))

          # Reference#object_level: how deep a sprite sits now. One that can be put in other
          # layers has a level for each, after the one it was declared at, and the number its
          # layer variable holds picks among them.
          def level_drawn_at(obj)
            levels = Stacking.levels_of(@stacking.depths, obj)
            return Statements::Int.new(levels.first) if levels.one?

            pick = call("rg_place_of_choice", variable(obj.layer_pick), Statements::Int.new(levels.length - 1))
            Statements::Index.new(drawing_array("levels", "int32_t", levels), pick)
          end

          # Which picture a sprite showing pose number +pose+ (one of its poses, already checked)
          # is DRAWN from, in the colors it is drawn with now. Its pictures are a row of poses in
          # its own colors, then a row for each list it can be drawn with
          # (Reference#object_recolor), and rg_place_of_choice returns which row it is on.
          #
          # A list that holds other colors as the game runs (a name where the colors would be)
          # has a row for every set it can hold, the ones it was declared with first, and the
          # set it holds now picks which of those rows (Reference#colors_held_by).
          def picture_drawn(obj, pose)
            return picture_following_pose_lists(obj, pose) if obj.follows_each

            lists = Array(obj.recolors)
            sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
            rows = sets.flatten(1).flat_map { |colors| obj.poses.map { |name| image_number(name, colors) } }
            pictures = drawing_array("pose_rows", "int32_t", rows)
            return Statements::Index.new(pictures, pose) if lists.empty?

            row = row_drawn_with(obj, lists, sets)
            Statements::Index.new(pictures, call("rg_add", call("rg_mul", row, Statements::Int.new(obj.poses.length)), pose))
          end

          # The same for a sprite whose poses are drawn from several lists, some of which it follows
          # (Object#follows_each, Reference#object_color_list). A pose drawn from a list it follows
          # has a picture for every set that list can hold, the declared one first; any other pose
          # has its one picture. They are kept one pose after another, so the picture drawn is
          # where the pose's pictures start plus the set its own list holds now, which is nothing
          # for a pose that follows no list.
          def picture_following_pose_lists(obj, pose)
            chosen = obj.poses.map { |name| lists_chosen_by_frame(obj, name) }
            followed = obj.poses.zip(chosen).map { |name, banks| obj.list_followed_by_pose(picture_named(name).colors_name) unless banks }
            pictures = obj.poses.zip(followed, chosen).map do |name, list, banks|
              next [image_number(name), *banks.compact.flat_map { |each| pictures_held_by(name, each) }] if banks

              list ? pictures_held_by(name, list) : [image_number(name)]
            end
            starts = pictures.each_with_object([0]) { |held, so_far| so_far << (so_far.last + held.length) }.first(pictures.length)
            lists = (followed + chosen.compact.flatten).compact.uniq
            writable = chosen.any? { |banks| banks&.any? }
            pose_lists = drawing_array("pose_lists", "int32_t", followed.map { |list| lists.index(list) || -1 }, writable: writable)
            pose_starts = drawing_array("pose_starts", "int32_t", starts, writable: writable)
            record_pose_lists_chosen_by_frames(obj, chosen, starts, lists, pose_lists, pose_starts) if writable
            list_of_pose = Statements::Index.new(pose_lists, pose)
            at = lists.each_with_index.reduce(Statements::Index.new(pose_starts, pose)) do |so_far, (list, number)|
              held = call("rg_place_of_choice", held_colors(list), Statements::Int.new(sets_held_by(list).length - 1))
              call("rg_add", so_far, call("rg_mul", call("rg_eq", list_of_pose, Statements::Int.new(number)), held))
            end
            Statements::Index.new(drawing_array("pose_pictures", "int32_t", pictures.flatten), at)
          end

          # The pictures of the pose +name+ in every set of colours the list +list+ can hold, the
          # declared one first.
          def pictures_held_by(name, list) = sets_held_by(list).map { |colors| image_number(name, colors) }

          # A POSE WHOSE LIST ITS FRAME PICKS AS THE GAME STARTS (IR::StartFile::Pose#bank_lists): for
          # each bank, the list of that bank where +obj+ follows it, or nil; nil for any other pose.
          # Such a pose has its own picture, in its frame's bank's colours, and then the pictures of
          # each followed bank's list; which of them it starts at, and which list it follows, are
          # written as the game starts (StartFileFills#record_pose_lists_chosen_by_frames).
          def lists_chosen_by_frame(obj, name)
            where = picture_from_start_file(name)&.from_file
            return nil unless where.is_a?(IR::StartFile::Pose) && where.bank_lists

            where.bank_lists.map { |list| list if obj.follows_each.include?(list) }
          end

          # Which row of its pictures a sprite is on: the first row of the list it is drawn with
          # now, and for a list that holds other colors, as many rows further as the set it holds.
          def row_drawn_with(obj, lists, sets)
            choice = call("rg_place_of_choice", value(obj.recolor), Statements::Int.new(lists.length))
            return choice if lists.none?(Symbol)

            first_rows = sets.each_with_object([0]) { |held, starts| starts << (starts.last + held.length) }
            row = Statements::Index.new(drawing_array("first_rows", "int32_t", first_rows.first(sets.length)), choice)
            lists.each_with_index.select { |colors, _| colors.is_a?(Symbol) }.reduce(row) do |so_far, (name, at)|
              held = call("rg_place_of_choice", held_colors(name), Statements::Int.new(sets_held_by(name).length - 1))
              call("rg_add", so_far, call("rg_mul", call("rg_eq", choice, Statements::Int.new(at + 1)), held))
            end
          end

          # Reference#colors_held_by: every set of colors a named list can hold, the ones it was
          # declared with first, which is also what a number naming none of the others means.
          def sets_held_by(name)
            list = @color_lists.fetch(name) { raise LoweringError, "a sprite is drawn with the list of colors #{name.inspect}, which is not declared" }
            [list.colors, *list.recolors]
          end

          # Which of its other sets each such list holds now (Reference @held_colors): a number
          # of the game's own for each, starting at the one that means the colors it was
          # declared with.
          def held_colors(name) = @names.of(:colors, name)

          def held_colors_globals
            @color_lists.each_key.map { |name| Statements::Global.new(name: held_colors(name), value: Build::NO_RECOLOR) }
          end

          # Reference#exec_color_list_holds. Nothing is painted here: everything drawn with the
          # list reads what it holds as it is next drawn. A backdrop that follows the list
          # (ColorList#backdrop_place) is given its colour in the set held now, from a table of the
          # one colour in each set, the declared set first as rg_place_of_choice counts them.
          def lower_color_list_holds(node)
            held = Statements::Assign.new(held_colors(node.name), value(node.which))
            followers = followed_tile_copies(node.name)
            place = @color_lists.fetch(node.name).backdrop_place
            return [held, *followers] unless place

            sets = sets_held_by(node.name)
            shown = sets.map { |set| set.fetch(place) }
            # A set read from the start file has a marker there, which the runtime reads as the
            # colour filled from the file (StartFileFills).
            marked = shown.any? { |color| IR::StartFile.marker?(color) }
            colors = drawing_array("backdrop_colors", "int32_t", shown.map { |color| IR::StartFile.marker?(color) ? color : color & 0x7FFF })
            choice = call("rg_place_of_choice", held_colors(node.name), Statements::Int.new(sets.length - 1))
            color = Statements::Index.new(colors, choice)
            color = call("rg_start_file_marked_color", start_file_colors_name, color) if marked
            [held, eval_call("rg_screen_show_backdrop", color), *followers]
          end

          # Reference#pixels_overlap?: each side's picture now, and where it is.
          def value_of_pixels_overlap(node)
            call("rg_pixels_overlap", picture_collided(node.a_poses, node.a_pose), value(node.a_x), value(node.a_y),
                 picture_collided(node.b_poses, node.b_pose), value(node.b_x), value(node.b_y))
          end

          # Which picture a sprite COLLIDES as: the one of +poses+ its pose names, in its own
          # colors whatever it is drawn with, since a swap of colors moves no pixel. The pose is
          # not checked first here; rg_pose_image reads it the way the interpreter does.
          def picture_collided(poses, pose)
            pictures = drawing_array("poses", "int32_t", poses.map { |name| image_number(name) })
            call("rg_pose_image", pictures, Statements::Int.new(poses.length), value(pose))
          end

          # Reference#exec_fade: over the whole screen, or placed in the stack under a layer, which
          # rg_screen.c knows by how far forward it is (IR::Stacking.at_or_above).
          def lower_fade(node)
            fade = [Statements::Int.new(node.toward == :white ? 1 : 0), fade_steps(node), walks_colors(node)]
            return [eval_call("rg_screen_fade_in_area", *fade_area(node), *fade.first(2))] if node.reaches
            return [eval_call("rg_screen_fade", *fade)] unless node.under

            [eval_call("rg_screen_fade_under", Statements::Int.new(stack_place(node.under)), *fade)]
          end

          # Which side of its rectangle a fade reaches, then the rectangle's four edges, as
          # rg_screen_fade_in_area takes them.
          def fade_area(node)
            side = node.reaches == :inside ? "RG_FADE_INSIDE" : "RG_FADE_OUTSIDE"
            [Statements::Name.new(side), *node.area.map { |edge| Statements::Int.new(edge) }]
          end

          # Reference#exec_pixelate. Where the blocks stop is not this statement's to set: a
          # program has one place for them, settled before it runs (#names_left_out_of_blocks).
          def lower_pixelate(node) = [eval_call("rg_screen_pixelate", value(node.size))]

          # Reference#exec_tint: counted in 256ths however it reaches the screen. Which way
          # it is mixed follows the screen up, which rg_screen.c knows.
          def lower_tint(node)
            steps = call("rg_fade_steps", value(node.amount), Statements::Int.new(node.fraction_bits || -1), Statements::Int.new(1))
            [eval_call("rg_screen_tint", color(node.color), steps)]
          end

          # 1 where this fade or tint walks the colors in 256ths rather than having the
          # display blend in sixteenths, which the whole program decides (see IR::Fading).
          def walks_colors(node) = Statements::Int.new(@fading.palette_walk?(node) ? 1 : 0)

          def fade_steps(node)
            call("rg_fade_steps", value(node.amount), Statements::Int.new(node.fraction_bits || -1), walks_colors(node))
          end

          # --- a scene taking the screen over (Reference#take_over) ---

          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            screen = if arrival.screen
                       lower_screen(arrival.screen)
                     else
                       screen_change("rg_screen_cross_to", Modes::SCREEN_OF_MODE.fetch(arrival.mode),
                                     arrival.mode == Modes::BUFFERED, arrival.backdrop)
                     end
            [eval_call("rg_scene_enter", Statements::Int.new(@scenes.fetch(scene))),
             *arrival.scenery.map { |bg| eval_call("rg_background_forget_cells", Statements::Int.new(entry_of(bg))) },
             *screen,
             eval_call("rg_scene_take_down", Statements::Int.new(arrival.scenery.empty? ? 0 : 1)),
             *arrival.map_choices.map { |var| assign(var, Statements::Int.new(0)) },
             *(arrival.painted_tiles + arrival.painted_pictures).map { |run| tile_copy(run) },
             *arrival.scenery.map { |bg| eval_call("rg_background_put_up", Statements::Int.new(entry_of(bg))) },
             eval_call("rg_scene_redraw_sprites", Statements::Int.new(arrival.scenery.empty? ? 0 : 1))]
          end

          # The number rg_screen.c knows this one declaration by. A name gives the entry that
          # keeps what the game does to it (RG_BG_KEPT_BY), which is another declaration's when
          # two scenes declare a background by one name, so a declaration is found by itself.
          def entry_of(bg)
            @stacking.scenery.index { |entry| entry.equal?(bg) } or
              raise LoweringError, "background #{bg.name.inspect} is not among the backgrounds the picture draws"
          end

          # --- small pieces ---

          def color(name) = Statements::Int.new(Graphics::Color.resolve(name))

          # 1 or 0, which is how a yes or a no is handed to the C.
          def yes_or_no(answer) = Statements::Int.new(answer ? 1 : 0)

          # A constant array for one drawing statement, kept to be written before the routines.
          # +writable+ is for one the routine that reads the start file writes into.
          def drawing_array(what, type, values, writable: false)
            name = @names.own("#{what}_#{@drawing_arrays.length + 1}")
            @drawing_arrays << Statements::ConstArray.new(name: name, type: type, values: values, writable: writable)
            name
          end
        end
      end
    end
  end
end
