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

      # Draws what the block says, for the player number it is handed.
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

      private

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
