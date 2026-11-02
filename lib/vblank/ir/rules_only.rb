# frozen_string_literal: true

module VBlank
  module IR
    # A GAME WITH NOTHING TO SEE OR HEAR: the program as a copy, with every step that makes a picture
    # or a sound left out and every other step just as written. A bot looking for a way through a
    # game plays one long run many times, and nearly all that time goes on pictures nobody looks at.
    #
    # ONLY THE VERBS GO, NEVER THE CODE AROUND THEM. A game can learn things while it draws: a ray
    # walk that fills a list of how far away each wall is, say, which then decides whether a shot
    # can land. So a routine that draws stays, with its arithmetic and everything it writes, and
    # only the steps that touch the screen or the speakers are gone. A game is no different to
    # itself for it, since nothing a game can read comes back from one of those steps.
    #
    # What declares something stays: a sprite's picture, a song, a font. A declaration does nothing
    # as the game runs, and a sum like two sprites' pixels overlapping reads the pictures themselves.
    module RulesOnly
      # What keeps a run playing at all, though it counts as drawing: the kind of screen a scene shows.
      STAYS = %i[screen].freeze

      module_function

      # A copy of +program+ with its pictures and sounds left out. +program+ is left as it was.
      def of(program)
        copy = program.copy
        copy.walk.to_a.each { |node| node.children.reject! { |child| left_out?(child) } }
        copy
      end

      def left_out?(node)
        %i[draw sound].include?(node.category) && node.class.role == :statement && !STAYS.include?(node.kind)
      end
    end
  end
end
