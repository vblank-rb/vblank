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
          # WHAT IS MADE SO FAR is a sprite shown over a painted picture (`over_picture: true`), in its own
          # colours or another list's, upright or turned and resized (Runtime::Turning). The plain sprite of a
          # painted screen is no sprite of this kind at all: the game paints it into the picture itself,
          # keeping and putting back the patch under it (Lowering#emit_save_region). Sprites a list puts in
          # order, and any sprite of a screen drawn from tiles, are each refused by name.
          #
          # A SPRITE DRAWN WITH ANOTHER LIST OF COLOURS (`draw_with`, `recolor`). The card has one palette
          # for the whole screen and a sprite's pixels are entries of it, so there is no list of a sprite's
          # own to swap. Each of the sprite's pictures is kept once more for every set of colours it can be
          # drawn in, made as the game is built by the rule every build shares (Assets::Recolor), and
          # placing the sprite picks which: its own, one of the lists it is told to draw with, or, for a
          # list the game changes (`recolor`), whichever set that list holds now (SET_HELD). Drawing one
          # costs what drawing any picture costs.
          module Sprites
            STATEMENT_KINDS = %i[present_objects color_list_holds].freeze

            # The part of the build a game with such a sprite waits for, for a test run to count skips by.
            PART = "sprites of a screen drawn from tiles, or put in order by a list"

            # Where a list of colours the game changes keeps which set it holds: nought for the colours it
            # was declared with, and one more than the set's number for each other.
            SET_HELD = "color list set held"

            def self.set_held_place(name) = [SET_HELD, name]

            # The lists of colours +program+ changes as it runs, by name.
            def self.color_lists_in(program) = program.walk.select { |node| node.kind == :color_list }.to_h { |node| [node.name, node] }

            # A place for each such list's number.
            def self.reserve(memory, program) = color_lists_in(program).each_key { |name| memory.reserve(set_held_place(name), 4) }

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
              return "that is not over a painted picture" unless sprite.over_picture

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
              return if sprite_objects.empty? # a pass ends by placing the sprites in a game with none too

              @asm.mov(runtime_at(Runtime::Sprites::PLACED), 0)
              node.names.each { |name| emit_sprite_placed(sprite_objects.fetch(name)) }
            end

            # One sprite put in the table, if it is shown and its pose picks one of its pictures.
            def emit_sprite_placed(sprite)
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
              @asm.mov(:bx, picture_image(sprite.poses.first).height) # a sprite's pictures are all one size
              @asm.call("rt_sprite_place")
              emit_sprite_turned(sprite) if Sprites.turns?(sprite)
              @asm.label(skip)
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
