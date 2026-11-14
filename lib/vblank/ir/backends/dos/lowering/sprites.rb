# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        class Lowering
          # SPRITES, PLACED FOR THE RUNTIME TO DRAW (Runtime::Sprites, which says how they reach the screen).
          # Mixed into Lowering.
          #
          # The game's step that places its sprites (`present_objects`, which the game loop runs each pass
          # where the console wants it) becomes, for each sprite in the order they are drawn: is it shown, which
          # of its pictures does its pose pick, and where is it, then a call that puts it in the runtime's
          # table. A sprite switched off, or one whose pose picks no picture, is not placed, which is what
          # "not drawn" means (Reference#objects_on_screen).
          #
          # WHAT IS MADE SO FAR is a sprite shown over a painted picture (`over_picture: true`), or over a screen
          # of tiles in front of all its scenery (Runtime::Scenery), in its own colours or another list's,
          # upright or turned and resized (Runtime::Turning). The plain sprite of a painted screen is no sprite
          # of this kind at all: the game paints it into the picture itself, keeping and putting back the patch
          # under it (Lowering#emit_save_region). Sprites a list puts in order are refused by name.
          #
          # A SPRITE DRAWN WITH ANOTHER LIST OF COLOURS (`draw_with`, `recolor`). The card has one palette
          # for the whole screen and a sprite's pixels are entries of it, so there is no list of a sprite's
          # own to swap. Each of the sprite's pictures is kept once more for every set of colours it can be
          # drawn in, made as the game is built by the rule every build shares (Assets::Recolor), and
          # placing the sprite picks which: its own, one of the lists it is told to draw with, or, for a
          # list the game changes (`recolor`), whichever set that list holds now (SET_HELD). Drawing one
          # costs what drawing any picture costs.
          module Sprites
            STATEMENT_KINDS = %i[present_objects color_list_holds hide_sprites load_sprite_tiles show_picture_group].freeze

            # Whether the next placing of the sprites places none (`hide_sprites`, Reference @sprites_hidden).
            HIDDEN = "sprites hidden"

            # The part of the build a game with such a sprite waits for, for a test run to count skips by.
            PART = "sprites put in order by a list"

            # Where a list of colours the game changes keeps which set it holds: nought for the colours it
            # was declared with, and one more than the set's number for each other.
            SET_HELD = "color list set held"

            def self.set_held_place(name) = [SET_HELD, name]

            # The lists of colours +program+ changes as it runs, by name.
            def self.color_lists_in(program) = program.walk.select { |node| node.kind == :color_list }.to_h { |node| [node.name, node] }

            # A place for each such list's number.
            def self.reserve(memory, program)
              color_lists_in(program).each_key { |name| memory.reserve(set_held_place(name), 4) }
              memory.reserve(HIDDEN, 4) if program.walk.any? { |node| node.kind == :hide_sprites }
            end

            # How many sprites +program+ has: none for a game that needs none of the runtime's sprites.
            def self.count_in(program) = program.walk.select { |node| node.kind == :object }.map(&:name).uniq.size

            def sprite_count = sprite_objects.size

            def sprite_objects = (@sprite_objects ||= @program.walk.select { |node| node.kind == :object }.to_h { |node| [node.name, node] })

            private

            def sprite_names = (@sprite_names ||= SpriteNames.new(@program))

            def refuse_unmade_sprites!
              sprite_objects.each_value do |sprite|
                what = unmade_in_sprite(sprite) or next
                raise NotMadeYet.new("This game has a sprite #{what}. The #{CONSOLE.title} build does not make that yet. " \
                                     "To fix this, show the sprite over a painted picture (`over_picture: true`), " \
                                     "upright and in its own colours, for now.", part: PART)
              end
              return unless @program.walk.any? { |node| node.kind == :present_objects && !node.orders.to_a.empty? }

              raise NotMadeYet.new("This game draws sprites in an order a list holds. The #{CONSOLE.title} build does " \
                                   "not make that yet. To fix this, leave the sprites in the order they are declared " \
                                   "for now.", part: PART)
            end

            # What about +sprite+ the build does not make yet, in words, or nil.
            def unmade_in_sprite(sprite)
              return "that is not over a painted picture" unless sprite.over_picture || tiled_screen?

              nil
            end

            def color_lists = (@color_lists ||= Sprites.color_lists_in(@program))

            # THE SETS OF COLOURS +sprite+ CAN BE DRAWN IN, in the order its table keeps them: nil for its
            # own, then for each list it can be told to draw with, that list's colours, or for a list the
            # game changes its declared colours and then each set it can hold.
            def color_sets(sprite) = [nil] + sprite.recolors.to_a.flat_map { |list| color_sets_of_list(list) }

            def color_sets_of_list(list)
              return [list] unless list.is_a?(Symbol)

              declared = color_lists.fetch(list) { raise LoweringError, "a sprite is drawn with the list #{list.inspect}, which is never declared" }
              [declared.colors, *declared.recolors]
            end

            # The 15-bit colour each pixel of the picture +name+ is drawn in with +set+ (Assets::Recolor), or
            # nil where it draws nothing.
            def recolored_pixels(name, set)
              image = picture_image(name)
              recolor = set && Assets::Recolor.of(image, set)
              (0...(image.width * image.height)).map do |at|
                next unless image.drawn_at?(at)

                color = image.color_at(at)
                Graphics::Color.resolve(recolor ? recolor.color_for(at, color) : color) & 0x7FFF
              end
            end

            # Every colour a sprite's pictures show in a set other than their own, for the palette.
            def recolored_sprite_colors
              sprite_objects.each_value.flat_map do |sprite|
                color_sets(sprite).compact.flat_map { |set| sprite.poses.flat_map { |name| recolored_pixels(name, set).compact } }
              end.uniq
            end

            # Where the picture +name+ drawn in +set+ is in the art segment, made the first time it is asked for.
            def recolored_place(name, set)
              return @art_places.fetch(name) if set.nil?

              @art_places[[:recolored, name, set]] ||= begin
                image = picture_image(name)
                place = @art.bytesize
                @art << [image.width, image.height].pack("v2")
                @art << recolored_pixels(name, set).map { |color| color ? palette_entry(color) : Runtime::TRANSPARENT }.pack("C*")
                place
              end
            end

            def constant_number?(node, number) = Sprites.constant_number?(node, number)

            def self.constant_number?(node, number) = node.is_a?(Node) && node.kind == :int && node.value == number

            # Whether +sprite+ turns or changes size as the game runs (Reference#object_transformed?), and whether
            # its size changes at all (#object_scales?): one that only turns reaches less of its patch.
            def self.turns?(sprite) = !(constant_number?(sprite.angle, 0) && constant_number?(sprite.scale, Build::SCALE_ONE))
            def self.scales?(sprite) = !constant_number?(sprite.scale, Build::SCALE_ONE)

            # Whether any sprite of +program+ does, so that the runtime carries the routine that draws one.
            def self.turned_in?(program) = program.walk.any? { |node| node.kind == :object && turns?(node) }

            # For each sprite, a table in the art segment of its pictures, for each set of colours it can be
            # drawn in (#color_sets) in the order its pose counts them: the place of each, and its number as
            # SpriteNames gives it, a word each. The number is the picture's whatever colours it is in.
            def make_sprite_tables
              sprite_objects.each_value do |sprite|
                rows = color_sets(sprite).flat_map do |set|
                  sprite.poses.flat_map { |name| [recolored_place(name, set), sprite_names.picture_number(name)] }
                end
                @art_places[sprite_key(sprite)] = @art.bytesize
                @art << rows.pack("v*")
              end
            end

            # The bytes of one set's rows in a sprite's table.
            def color_set_bytes(sprite) = sprite.poses.size * 4

            # Reference#exec_color_list_holds: the set a list holds from now on, kept as SET_HELD keeps it. A
            # number that names no set is the colours the list was declared with.
            def emit_color_list_holds(node)
              sets = color_lists.fetch(node.name).recolors.size
              inside = fresh_label("color_set_named")
              emit_value(node.which)
              @asm.cmp(:eax, sets) # as numbers with no sign, so one below nought names none either
              @asm.jb(inside)
              @asm.mov(:eax, -1)
              @asm.label(inside)
              @asm.inc(:eax)
              @asm.mov(runtime_at(Sprites.set_held_place(node.name)), :eax)
            end

            # Reference#object_color_list, for a sprite that can be drawn in more than its own colours: how
            # far into its table, in bytes, the rows of the set it is drawn in now begin, into EAX. A number that
            # picks none of its lists is its own colours. Changes EDX.
            def emit_color_set_offset(sprite)
              chosen = fresh_label("color_set_chosen")
              emit_value(sprite.recolor)
              first = 1 # the set after the sprite's own
              sprite.recolors.each_with_index do |list, which|
                other = fresh_label("color_set_other")
                @asm.cmp(:eax, which)
                @asm.jne(other)
                if list.is_a?(Symbol)
                  @asm.mov(:eax, runtime_at(Sprites.set_held_place(list)))
                  @asm.add(:eax, first)
                else
                  @asm.mov(:eax, first)
                end
                @asm.jmp(chosen)
                @asm.label(other)
                first += color_sets_of_list(list).size
              end
              @asm.xor(:eax, :eax)
              @asm.label(chosen)
              @asm.mov(:edx, color_set_bytes(sprite))
              @asm.imul(:eax, :edx)
            end

            def sprite_key(sprite) = [:sprite, sprite.name]

            # Every picture a sprite can show, so each is in the art and its colours in the palette.
            def sprite_pictures = sprite_objects.each_value.flat_map(&:poses)

            # Reference#exec_present_objects, for sprites over a painted picture: the table emptied, and each
            # sprite on the screen put in it. (`hide_sprites`, which makes a placing place none, is refused on
            # a painted screen before any build, so nothing here answers it.)
            def emit_present_objects(node)
              # In a game that scrolls the interpreter builds the view again as the sprites are placed (Reference
              # @repaints); Runtime::Scenery leaves a build that would make the picture it shows.
              if sprites_stacked?
                @asm.call("rt_scenery_rebuild") # the view holds the sprites as they were placed
              elsif scenery_used? && scenery_rebuilt_each_pass?
                @asm.call("rt_scenery_request")
              end
              return if sprite_objects.empty? # a pass ends by placing the sprites in a game with none too

              @asm.mov(runtime_at(Runtime::Sprites::PLACED), 0)
              sprites = node.names.map { |name| sprite_objects.fetch(name) }
              placed = fresh_label("sprites_placed")
              if @memory.places.key?(HIDDEN)
                shown = fresh_label("sprites_shown")
                @asm.cmp(runtime_at(HIDDEN), 0)
                @asm.je(shown)
                @asm.mov(runtime_at(HIDDEN), 0) # this one placing, and the next places them all again
                @asm.jmp(placed)
                @asm.label(shown)
              end
              emit_sprites_placed(sprites)
              @asm.label(placed)
            end

            # --- sprites drawn from tiles the game loads, and picture groups ---
            #
            # PICTURE GROUPS change nothing here: they say which of a game's pictures a console keeps in its sprite
            # memory, and a DOS program keeps every picture in reach all the time. A picture shown while its group is
            # not up stops the interpreter, which the checked run plays beside this, as on the builds for a computer.
            #
            # A POSE DRAWN FROM SPRITE TILES THE GAME LOADS (`sprite_tiles`, `tile_pose`) is a picture in the art
            # segment like any other, see-through all over until the first load (Reference#store_tile_pose_picture),
            # and a load writes the tiles it brings into each pose that draws them, a palette entry a pixel through the
            # set's colours (rt_paint_sprite_tile), as the C build's rg_tile_pose_load does.

            def sprite_tile_sets = (@sprite_tile_sets ||= @program.walk.select { |node| node.kind == :sprite_tiles }.to_h { |node| [node.name, node] })
            def tile_poses = (@tile_poses ||= @program.walk.select { |node| node.kind == :tile_pose }.to_h { |node| [node.name, node] })

            # A tile pose's picture before any load: see-through all over, in its set's colours, every pixel at place nought.
            def tile_pose_image(name)
              pose = tile_poses[name] or return
              set = sprite_tile_sets.fetch(pose.tiles)
              pixels = pose.width * pose.height
              Assets::Image.new(width: pose.width, height: pose.height, transparent: Graphics::Image::TRANSPARENT,
                                pixels: Array.new(pixels, Graphics::Image::TRANSPARENT).pack("v*"),
                                colors: set.colors, places: Array.new(pixels, 0).pack("C*"), colors_name: set.colors_name)
            end

            # The colours a loaded tile of +set+ shows by place in a pose drawn with +swapped+ (nil for its own): the
            # swapped list's colour at the place, or the set's own where it has none (Assets::Recolor, by place).
            def tile_colors_by_place(set, swapped) = Array.new(16) { |place| (swapped && swapped[place]) || set.colors[place] }

            # Every colour a loaded tile can draw, in its set's colours and in every list a sprite showing one of its poses
            # is drawn with, for the palette.
            def sprite_tile_colors
              own = sprite_tile_sets.each_value.flat_map { |set| set.colors.drop(1).compact }
              swapped = sprite_objects.each_value.flat_map do |sprite|
                sprite.poses.filter_map { |name| tile_poses[name] }.flat_map do |pose|
                  color_sets(sprite).compact.flat_map { |list| tile_colors_by_place(sprite_tile_sets.fetch(pose.tiles), list).drop(1).compact }
                end
              end
              own + swapped
            end

            # Each copy of +pose+'s picture in the art segment, with where the colours its tiles are painted in are: its
            # own, and one for each list a sprite showing it is drawn with (Lowering::Sprites#recolored_place). None for a
            # pose no sprite shows, which has no picture.
            def tile_pose_copies(pose)
              return [] unless @art_places.key?(pose.name)

              recolored = @art_places.each_key.select { |key| key.is_a?(Array) && key.first == :recolored && key[1] == pose.name }
              [[@art_places.fetch(pose.name), nil], *recolored.map { |key| [@art_places.fetch(key), key[2]] }].map do |place, swapped|
                [place, tile_colors_place(pose.tiles, swapped)]
              end
            end

            # Where a set's colours drawn with +swapped+ are, as palette entries by place, place nought see-through: made the
            # first time they are asked for.
            def tile_colors_place(set_name, swapped)
              @art_places[[:sprite_tile_colors, set_name, swapped]] ||= begin
                colors = tile_colors_by_place(sprite_tile_sets.fetch(set_name), swapped)
                place = @art.bytesize
                @art << Array.new(16) { |at| at.zero? || colors[at].nil? ? Runtime::TRANSPARENT : palette_entry(colors[at]) }.pack("C*")
                place
              end
            end

            # Each table a load reads that nothing else reads, laid out as Lowering#make_tables lays them; and the colours
            # every copy of every pose a load paints is painted in.
            def make_sprite_tile_art
              @program.walk.select { |node| node.kind == :load_sprite_tiles }.map(&:table).uniq.each do |name|
                next if @art_places.key?(table_key(name))

                table = @plan.tables.fetch(name)
                bytes, = @plan.table_keeping(table)
                @art_places[table_key(name)] = @art.bytesize
                @art << table.values.flat_map { |entry| Array.new(bytes) { |i| (Int32.wrap(entry) >> (8 * i)) & 0xFF } }.pack("C*")
              end
              @tile_pose_copies = tile_poses.transform_values { |pose| tile_pose_copies(pose) }
            end

            # Reference#exec_load_sprite_tiles: where from and where to worked out, and nothing loaded unless the load
            # fits the table and the set (LoweringPlan.sprite_tile_load_bounds); then each piece of each copy of each pose
            # drawn from the set whose tile the load brings painted again, and every sprite drawn again.
            def emit_load_sprite_tiles(node)
              set = sprite_tile_sets.fetch(node.name)
              table = @plan.tables.fetch(node.table)
              bounds = LoweringPlan.sprite_tile_load_bounds(node, table_bytes: table.values.length, set_count: set.count) or return
              bytes, = @plan.table_keeping(table)
              from = keep_local(:load_from)
              to = keep_local(:load_to)
              done = fresh_label("tiles_not_loaded")
              emit_values_into(%i[eax ecx], [value_node(node.at), value_node(node.to)])
              @asm.cmp(:eax, bounds[0][1])
              @asm.ja(done) # with no sign: below nought is past the end too
              @asm.cmp(:ecx, bounds[1][1])
              @asm.ja(done)
              @asm.mov(number_at(from), :eax)
              @asm.mov(number_at(to), :ecx)
              load = TileLoad.new(node: node, table: table, bytes: bytes, from: from, to: to)
              tile_poses.each_value.select { |pose| pose.tiles == node.name }.each do |pose|
                @tile_pose_copies.fetch(pose.name).each do |picture, colors|
                  pose.pieces.each { |dx, dy, tile| emit_tile_piece_loaded(load, picture + 4 + (dy * pose.width) + dx, pose.width, colors, tile) }
                end
              end
              @asm.mov(X86.mem(nil, @memory[Runtime::Sprites::PLACED_BEFORE], size: 16), 0xFFFF) if sprite_count.positive?
              @asm.call("rt_scenery_rebuild") if scenery_used?
              @asm.label(done)
            end

            # One load of sprite tiles as it is written: the step, its table, the bytes an entry of the table takes, and the
            # numbers that hold where it loads from and to.
            TileLoad = Data.define(:node, :table, :bytes, :from, :to)

            # One piece of a pose's picture painted from the table, its top left at +at+ in a picture +width+ pixels wide,
            # through the colours at +colors+, where the load brings its tile.
            def emit_tile_piece_loaded(load, at, width, colors, tile)
              skip = fresh_label("piece_not_loaded")
              @asm.mov(:eax, tile)
              @asm.sub(:eax, number_at(load.to))
              @asm.cmp(:eax, load.node.count)
              @asm.jae(skip)
              @asm.add(:eax, number_at(load.from))
              @asm.mov(:ebx, Nodes::LoadSpriteTiles::TILE_BYTES * load.bytes)
              @asm.imul(:eax, :ebx)
              @asm.add(:ax, @art_places.fetch(table_key(load.table.name)))
              @asm.mov(:si, :ax)
              @asm.mov(:di, at)
              @asm.mov(:bx, colors)
              @asm.mov(:dx, width)
              @asm.mov(:cx, load.bytes)
              @asm.call("rt_paint_sprite_tile")
              @asm.label(skip)
            end

            # Reference#exec_hide_sprites: the next placing places none.
            def emit_hide_sprites = @asm.mov(runtime_at(HIDDEN), 1)

            # Each of +sprites+ put in the table, in the order they are drawn, or a level at a time in a game whose
            # sprites are drawn at their levels.
            def emit_sprites_placed(sprites)
              return sprites.each { |sprite| emit_sprite_placed(sprite) } unless sprites_stacked?

              emit_sprites_by_level(sprites)
            end

            # Sprites drawn into the view at their levels, placed a level at a time from the back, in the order they
            # are drawn inside each: the table is then back to front, as the interpreter counts the sprites drawn
            # (Reference#sprites_by_depth). A sprite that can be put in other layers is placed at the level its
            # variable picks now.
            def emit_sprites_by_level(sprites)
              depths = stacked_picture.depths
              sprites.flat_map { |sprite| Stacking.levels_of(depths, sprite) }.uniq.sort.each do |level|
                sprites.each do |sprite|
                  levels = Stacking.levels_of(depths, sprite)
                  next unless levels.include?(level)
                  next emit_sprite_placed(sprite, level) if levels.uniq.size == 1

                  elsewhere = fresh_label("sprite_at_another_level")
                  emit_sprite_level(sprite)
                  @asm.cmp(:dl, level)
                  @asm.jne(elsewhere)
                  emit_sprite_placed(sprite, level)
                  @asm.label(elsewhere)
                end
              end
            end

            # One sprite put in the table, if it is shown and its pose picks one of its pictures; with its +level+
            # in the stack, in a game whose sprites are drawn at their levels.
            def emit_sprite_placed(sprite, level = nil)
              skip = fresh_label("sprite_not_drawn")
              recolored = !sprite.recolors.to_a.empty?
              emit_value(sprite.active)
              @asm.cmp(:eax, 1)
              @asm.jne(skip)
              if recolored
                emit_color_set_offset(sprite)
                @asm.push(:ax)
              end
              emit_value(sprite.pose)
              @asm.pop(:dx) if recolored # before the test, so the stack is the same either way out
              @asm.cmp(:eax, sprite.poses.size) # as numbers with no sign, so one below nought is too big as well
              @asm.jae(skip)
              # The picture's place into SI and its number into DI, from the sprite's table.
              @asm.mov(:bx, :ax)
              @asm.shl(:bx, 2)
              @asm.add(:bx, :dx) if recolored
              @asm.add(:bx, @art_places.fetch(sprite_key(sprite)))
              @asm.mov_segment(:cx, :art)
              @asm.push(:ds)
              @asm.mov(:ds, :cx)
              @asm.mov(:si, X86.mem(:bx, 0))
              @asm.mov(:di, X86.mem(:bx, 2))
              @asm.pop(:ds)
              @asm.push(:si)
              @asm.push(:di)
              emit_values_into(%i[eax ecx], [value_node(sprite.x), value_node(sprite.y)])
              @asm.pop(:di)
              @asm.pop(:si)
              @asm.mov(:dx, sprite_names.name_number(sprite.declared))
              @asm.call("rt_sprite_place")
              emit_sprite_turned(sprite) if Sprites.turns?(sprite)
              emit_sprite_off_while_painted(sprite)
              if level
                # The level of the sprite just placed (Runtime::Sprites::LEVELS).
                @asm.mov(:bx, X86.mem(nil, @memory[Runtime::Sprites::PLACED], size: 16))
                @asm.mov(X86.mem(:bx, @memory[Runtime::Sprites::LEVELS] - 1, size: 8), level)
              end
              @asm.label(skip)
            end

            # DL the level in the stack of a sprite that can be put in other layers, as Reference#object_level works
            # it out: the one its variable picks, where it picks one of them, or the one it was declared at.
            def emit_sprite_level(sprite)
              levels = Stacking.levels_of(stacked_picture.depths, sprite)
              emit_value(sprite.layer_pick)
              @asm.mov(:dl, levels.first)
              levels.drop(1).each_with_index do |level, pick|
                other = fresh_label("sprite_layer_other")
                @asm.cmp(:eax, pick)
                @asm.jne(other)
                @asm.mov(:dl, level)
                @asm.label(other)
              end
            end

            # THE SPRITES OF A SCREEN OF TILES ARE OFF WHILE A PAINTED SCREEN IS UP, in a game that shows both kinds
            # (Reference#exec_present_objects): the sprite just placed is still in the table, which is what the game has
            # drawn as the interpreter counts it, but shows a picture of nothing and takes no rows. A sprite over the
            # picture (`over_picture: true`) is the painted screen's own and shows.
            def emit_sprite_off_while_painted(sprite)
              return if sprite.over_picture || !scenery_used? || !crosses_screens?

              shows = fresh_label("sprite_shows")
              entry = ->(part, size) { X86.mem(:bx, part, size: size) }
              @asm.cmp(runtime_at(Runtime::Scenery::SCREEN_KIND), Runtime::Scenery::PAINTED)
              @asm.jne(shows)
              @asm.mov(:bx, X86.mem(nil, @memory[Runtime::Sprites::PLACED], size: 16))
              @asm.dec(:bx)
              @asm.shl(:bx, Runtime::Sprites.entry_shift(@memory))
              @asm.add(:bx, @memory[Runtime::Sprites::TABLE])
              @asm.mov(entry.call(Runtime::Sprites::ART, 16), @art_places.fetch(:no_picture))
              @asm.mov(entry.call(Runtime::Sprites::HEIGHT, 16), 0)
              @asm.mov(entry.call(Runtime::Sprites::TURNS, 16), 0) if Runtime::Sprites.turned?(@memory)
              @asm.label(shows)
            end

            # The sprite just placed turns (Runtime::Turning): its angle and its size as they are now, and what
            # is settled as the game is built, its picture's width and the rows of its patch it can reach.
            def emit_sprite_turned(sprite)
              image = picture_image(sprite.poses.first)
              reached = Affine.rows_reached(image.width, image.height, scales: Sprites.scales?(sprite))
              emit_values_into(%i[eax ecx], [value_node(sprite.angle), value_node(sprite.scale)])
              @asm.mov(:dx, image.width)
              @asm.mov(:bx, reached.begin)
              @asm.mov(:si, reached.end)
              @asm.call("rt_sprite_turned")
            end
          end
        end
      end
    end
  end
end
