# frozen_string_literal: true

module VBlank
  module IR
    # A GAME WITH NOTHING TO SEE OR HEAR: the program as a copy, with every step that only makes a
    # picture or a sound left out and every other step just as written, for a bot that plays one
    # long run many times (Backends::Native::RulesRun).
    #
    # ONLY THE VERBS GO, NEVER THE CODE AROUND THEM. A game can learn things while it draws: a ray
    # walk that fills a list of how far away each wall is, say, which then decides whether a shot
    # can land. So a routine that draws stays, with its arithmetic and everything it writes.
    #
    # What declares something stays too: a sprite's picture, a song, a font. A declaration does
    # nothing as the game runs, and a sum like two sprites' pixels overlapping reads the pictures.
    module RulesOnly
      # Steps that count as drawing and that a game's rules can read back, so they stay. A background
      # and its maps are what a sprite walks into, and which map is up comes back to its first as a
      # scene takes over; a bend's rows run a block of the game's own; and a list of colours left
      # unread is a C build's error. None of them paints anything until a picture is asked for,
      # and here none is.
      STAY = %i[screen background show_map set_tile scroll_rows background_colors color_list_holds].freeze

      module_function

      # A copy of +program+ with its pictures and sounds left out. +program+ is left as it was.
      def copy_of(program)
        copy = program.copy
        copy.walk.to_a.each { |node| node.children.reject! { |child| left_out?(child) } }
        copy
      end

      def left_out?(node)
        %i[draw sound].include?(node.category) && node.class.role == :statement && !STAY.include?(node.kind)
      end
    end
  end
end
