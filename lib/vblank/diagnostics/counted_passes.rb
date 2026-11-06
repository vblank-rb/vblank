# frozen_string_literal: true

module VBlank
  module Diagnostics
    # HOW MANY TIMES ROUND THE GAME LOOP A CONSOLE GOT, for one whose runtime counts it: the passes
    # it finished (see Verifier for what a pass is). The Color's runtime and the Super Nintendo's
    # each keep a count of their own, so this reads that and costs nothing — +count_passes:+ is
    # not needed. Nil for a program with no game loop.
    #
    # WHAT THE RUNTIME COUNTS is the times the game waited for the screen, which is the passes
    # only for a game loop that waits for it once, at its top — the way `game_loop` waits unless
    # it is told `frame_sync: :manual`. It is then one ahead: the first wait comes before the first
    # pass has run at all, so after the bodies of thirty passes the count reads thirty-one, whether
    # the run stopped at the next wait or part way through the next body. A game that waits
    # anywhere else is refused the count, since the waits are then not the passes.
    module CountedPasses
      def passes
        refuse_missing_build_record!("where it counts its passes")
        ensure_rendered!
        program = @rom.source_program
        return nil if program.walk.none? { |node| node.kind == :loop } # what `game_loop` makes

        refuse_waits_not_passes! unless IR::Frames.waits_only_at_loop_top?(program)
        [var_at(@rom.built.waits_counted_at) - 1, 0].max
      end

      private

      # The runtime counts its own passes (see #passes), so there is nothing to watch.
      def watch_passes! = nil

      def refuse_waits_not_passes!
        raise ArgumentError, "This game waits for the screen in places of its own (`wait_vblank`, or " \
                             "`frame_sync: :manual`). A #{kit.title} counts the waits, not the passes of the " \
                             "game loop, so this cartridge cannot say its passes. Count them in a variable of " \
                             "the game's own, and read it with `var`."
      end
    end
  end
end
