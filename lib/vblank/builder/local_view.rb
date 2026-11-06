# frozen_string_literal: true

module VBlank
  class Builder
    # WHAT ONLY THIS MACHINE'S PERSON SEES. In a match played over a network every machine runs the
    # whole game, and must run the same game: if the game read a number that is different on each
    # machine (which player I am) and let it reach a variable, the machines would drift apart and the
    # match would stop at the next checkpoint. But a game wants to know who it is playing for, to mark
    # the player's own walker, or to centre a camera on it. So the number is given out in one place
    # only, a block that may draw and may not change the game:
    #
    #   drawing_for_local_player do |me|
    #     draw_text "YOU", hero.x, hero.y - 8, :white if me == 1
    #   end
    #
    # The build holds the game to that in two ways. Every statement in the block must be a drawing one
    # (or an `if` around drawing ones), so a variable, a list, a pool, a call, a sound and a random draw
    # are refused where they are written; and the number itself, which is `me`, is refused anywhere
    # outside such a block, even when the block kept it in a Ruby variable. What is drawn on one
    # machine and not on another changes the picture and nothing the game remembers.
    #
    # On a cartridge, and in a game played alone, `me` is 1.
    module LocalView
      # What a view may hold: everything the game draws, `if` to choose what to draw, and the
      # declarations drawing needs (a picture, a letter), which do nothing where they are written.
      DECLARATIONS = %i[declaration part].freeze

      # Draws what the block asks for, for the player number it is handed.
      def drawing_for_local_player
        unless block_given?
          raise ArgumentError, "`drawing_for_local_player` needs a block. To fix this, write the drawing in it: " \
                               "`drawing_for_local_player { |me| draw_text \"YOU\", 8, 8, :white if me == 1 }`."
        end

        me = DSL::Value.new(self, @for_computer ? Build.local_player : Build.int(1))
        container = @container_stack.last
        before = container.children.size
        yield me
        views = container.children.drop(before)
        views.each { |statement| refuse_writes_outside_drawing!(statement) }
        @view_statements.concat(views)
        nil
      end

      # A picture shown over +over+ (a sprite of the console's: any sprite on a `screen :tiled`, or one
      # made with `over_picture: true`), centred just above it, and moved +offset+ [dx, dy] from there.
      #
      #   drawing_for_local_player do |me|
      #     walkers.each.with_index(1) { |walker, player| mark over: walker, with: :arrow if me == player }
      #   end
      #
      # WHY A MARK HAS NO VARIABLES. A tiled screen shows only sprites and backgrounds, so the "you"
      # arrow over a walker must be a sprite. But an ordinary sprite's place and its shown flag are
      # game variables, and in a match the variables are what every machine checks against every
      # other: an arrow moved or shown from `me` would differ from machine to machine, and the match
      # would stop. Two shapes were weighed. One was a sprite marked `local: true`, whose variables
      # the state number leaves out and which may be written only in the block: it needs every
      # runtime to learn which variables to skip, and a game could still read them into its real
      # state, which the build would have to chase. The shape taken is the other one: a sprite whose
      # place and shown flag are not variables at all but sums the console works out on every frame
      # from the marked sprite's own (`hero.x + 4`, "hero is shown, and `me == 2`"). There is
      # nothing the game can write, nothing the state number has to leave out, and no lowering
      # learns anything new: every one already draws a sprite at a place worked out from numbers.
      # The guarantee stays the build's to check, as the block's is: `me` may be in the sums only
      # when the mark is written inside `drawing_for_local_player`.
      #
      # It is not only for a match: a label over a boss is a mark too. A game with no `mark` builds
      # the same bytes as before.
      def mark(over:, with:, offset: [0, 0])
        refuse_unmarkable_sprite!(over, with)
        mark_width, mark_height = resolve_sprite_art(with, nil, nil, subject: "mark")[2, 2]
        sprite_width = @images.fetch(over.collision_poses.first, [mark_width])[0]
        dx, dy = offset
        x = over.x + (((sprite_width - mark_width) / 2) + dx)
        y = over.y + (dy - mark_height)
        node = over.object_node
        name = :"__mark#{@sprite_seq += 1}"
        record(Build.object(name, poses: [with], pose: Build.int(0),
                                  x: DSL::Value.node_for(x), y: DSL::Value.node_for(y),
                                  active: gated_by_open_conditions(gated_by_scene(node.active.copy)),
                                  scene: declaring_scene || node.scene, declared: with, layer: node.layer,
                                  over_picture: node.over_picture))
        @sprite_objects << name
        DSL::Mark.new(node.declared)
      end

      private

      def refuse_unmarkable_sprite!(over, with)
        return if over.is_a?(DSL::HardwareSprite)

        raise ArgumentError, "`mark over:` needs a sprite that the console shows. The game gave it a " \
                             "#{over.class.name.split('::').last}. Each sprite on a `screen :tiled` is one. On a " \
                             "`screen :bitmap`, make the sprite with `over_picture: true`. Or draw the picture " \
                             "with `blit :#{with}, x, y` at the place of the sprite."
      end

      # Raises for the first statement under +statement+ that is not a drawing one.
      def refuse_writes_outside_drawing!(statement)
        statement.each do |inner|
          next if inner.category == :draw || inner.kind == :if || DECLARATIONS.include?(inner.class.role)

          raise ArgumentError, "`drawing_for_local_player` can only draw, and #{view_line(inner)} changes the " \
                               "game (#{inner.kind}). Each machine has its own player number, so a game that " \
                               "keeps it would play differently on each. To fix this, move that line out of " \
                               "the block, and keep only drawing in it."
        end
      end

      def view_line(node) = node.source ? "the line at #{node.source}" : "a line in the block"

      # Raises when the player number is used anywhere but in a view: once the whole game is built,
      # since a number kept in a Ruby variable can be used a long way from the block that made it.
      def refuse_local_player_outside_views!
        views = @view_statements.to_set(&:object_id)
        outside = outside_of_views(@program, views).first
        return unless outside

        raise ArgumentError, "The player number of this machine (`me` in `drawing_for_local_player`) is used " \
                             "outside that block, #{view_line(outside)}. Each machine has its own number, " \
                             "so a game that keeps it would play differently on each. To fix this, use `me` " \
                             "only inside the block, and only to choose what to draw."
      end

      # Every `local_player` value in +node+ that is not under a view statement.
      def outside_of_views(node, views)
        return [] if views.include?(node.object_id)

        own = node.kind == :local_player ? [node] : []
        own + node.attrs.values.flatten.grep(IR::Node).flat_map { |inner| outside_of_views(inner, views) } +
          node.children.flat_map { |inner| outside_of_views(inner, views) }
      end
    end
  end
end
