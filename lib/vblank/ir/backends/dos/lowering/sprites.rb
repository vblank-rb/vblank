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
          # WHAT IS MADE SO FAR is a sprite shown over a painted picture (`over_picture: true`), upright and
          # in its own colours. One painted into the picture, one that turns or changes size, one drawn in
          # another list of colours, and sprites a list puts in order are each refused by name.
          module Sprites
            STATEMENT_KINDS = %i[present_objects].freeze

            # The part of the build a game with such a sprite waits for, for a test run to count skips by.
            PART = "sprites painted into the picture, turned, resized, recoloured or put in order by a list"

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
              return "painted into the picture" unless sprite.over_picture
              return "that turns or changes size" unless constant_number?(sprite.angle, 0) && constant_number?(sprite.scale, Build::SCALE_ONE)
              return "drawn in another list of colours" unless sprite.recolors.to_a.empty? && sprite.follows.nil?

              nil
            end

            def constant_number?(node, number) = node.is_a?(Node) && node.kind == :int && node.value == number

            # For each sprite, a table in the art segment of its pictures in the order its pose counts them: the
            # place of each, and its number as SpriteNames gives it, a word each.
            def make_sprite_tables
              sprite_objects.each_value do |sprite|
                rows = sprite.poses.flat_map { |name| [@art_places.fetch(name), sprite_names.picture_number(name)] }
                @art_places[sprite_key(sprite)] = @art.bytesize
                @art << rows.pack("v*")
              end
            end

            def sprite_key(sprite) = [:sprite, sprite.name]

            # Every picture a sprite can show, so each is in the art and its colours in the palette.
            def sprite_pictures = sprite_objects.each_value.flat_map(&:poses)

            # Reference#exec_present_objects, for sprites over a painted picture: the table emptied, and each
            # sprite on the screen put in it. (`hide_sprites`, which makes a placing place none, is refused on
            # a painted screen before any build, so nothing here answers it.)
            def emit_present_objects(node)
              @asm.mov(runtime_at(Runtime::Sprites::PLACED), 0)
              node.names.each { |name| emit_sprite_placed(sprite_objects.fetch(name)) }
            end

            # One sprite put in the table, if it is shown and its pose picks one of its pictures.
            def emit_sprite_placed(sprite)
              skip = fresh_label("sprite_not_drawn")
              emit_value(sprite.active)
              @asm.cmp(:eax, 1)
              @asm.jne(skip)
              emit_value(sprite.pose)
              @asm.cmp(:eax, sprite.poses.size) # as numbers with no sign, so one below nought is too big as well
              @asm.jae(skip)
              # The picture's place into SI and its number into DI, from the sprite's table.
              @asm.mov(:bx, :ax)
              @asm.shl(:bx, 2)
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
              @asm.label(skip)
            end
          end
        end
      end
    end
  end
end
