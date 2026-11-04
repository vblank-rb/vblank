# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHAT A CARTRIDGE BUILD WORKS OUT FROM ITS PROGRAM ALONE, ONCE, FOR EVERY TRY. A console whose
      # cartridge is seen a bank at a time builds a game by trying: a try lowers the whole game, and
      # stops at the first thing that does not fit (too many tiles, too many lists of colours, a part
      # of the cartridge too full), which says what the next try changes. A big game takes several.
      # But much of what a try works out has nothing to do with how it is built: what a run reaches
      # and the numbers scenes are known by (LoweringPlan), what each scene hands the next
      # (SceneHandover), how the layers stack (Stacking), each picture's pixels (Assets::Image), and
      # what a tile's picture alone says about its colours. Those are worked out here, once a build,
      # and every try reads them.
      #
      # So the one rule for what goes in: it depends on the program and the console, and on nothing
      # a try chooses, and nothing a try does changes it. What a try chooses — where a tile goes,
      # which palette it takes, where a number is kept — stays in that try's Lowering and Art. The
      # one exception is a hint about cost that decides nothing: the routines an earlier try found
      # too big for a bank (RoutineCuts' +found_too_big+), which a later try measures first.
      #
      # The console's build makes one for each build and hands it to each try's Lowering; a Lowering
      # made on its own (a test) makes its own.
      class BuildCache
        attr_reader :program

        def initialize(program, console:, error:)
          @program = program
          @console = console
          @error = error
          @images = {}.compare_by_identity
          @facts = {}
        end

        # What the program is before any instruction is made (LoweringPlan): its refusals raise the
        # lowering's own +error+.
        def plan = @plan ||= LoweringPlan.new(@program, console: @console, error: @error)

        # What each scene hands the next (SceneHandover).
        def handover = plan.handover

        # How the program's layers stack (Stacking.picture).
        def stacking = @stacking ||= Stacking.picture(@program)

        # The picture +node+ declares, read pixel by pixel once (Assets::Image.of). Kept by which node
        # it is: a node's own hash walks everything under it.
        def image(node) = @images[node] ||= Assets::Image.of(node)

        # Any other fact a lowering works out from the program alone, by a +key+ of its own: worked
        # out by the block the first time it is asked, and the same answer every time after.
        def fetch(key)
          return @facts[key] if @facts.key?(key)

          @facts[key] = yield
        end
      end
    end
  end
end
