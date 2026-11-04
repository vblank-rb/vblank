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
      # What goes in depends on the program and the console, and on nothing a try chooses: what a
      # try chooses — where a tile goes, which palette it takes, where a number is kept — stays in
      # that try's Lowering and Art. Tries add to it only as a memo adds to itself: an answer once
      # worked out is the answer for every later try. The one thing a try adds that is not such an
      # answer is a hint about cost that decides nothing: the routines it found too big for a bank
      # (#routines_found_too_big), which a later try measures before it makes them.
      #
      # A console's build makes one at the start of each build (BuildCache.for) and hands it to
      # every try; nothing keeps it once the build returns. A Lowering made on its own (a test)
      # makes its own.
      class BuildCache
        # A cache for a build of +program+ by the cartridge backend +backend+ (GBC, SNES, Genesis):
        # its Lowering says the console and what else that console keeps (its BuildFacts), and its
        # LoweringError is what the plan's refusals raise.
        def self.for(backend, program) = new(program, lowering: backend::Lowering, error: backend::LoweringError)

        attr_reader :program

        # The statements of each routine an earlier try of the build cut to fit a bank, each list by
        # the identity of the nodes in it (RoutineCuts#sections).
        attr_reader :routines_found_too_big

        def initialize(program, lowering:, error:)
          @program = program
          @lowering = lowering
          @error = error
          @images = {}.compare_by_identity
          @routines_found_too_big = Set.new
        end

        # What the program is before any instruction is made (LoweringPlan): its refusals raise the
        # lowering's own error.
        def plan = @plan ||= LoweringPlan.new(@program, console: @lowering::CONSOLE, error: @error)

        # What each scene hands the next (SceneHandover).
        def handover = plan.handover

        # How the program's layers stack (Stacking.picture).
        def stacking = @stacking ||= Stacking.picture(@program)

        # The picture +node+ declares, read pixel by pixel once (Assets::Image.of). Kept by which node
        # it is: a node's own hash walks everything under it.
        def image(node) = @images[node] ||= Assets::Image.of(node)

        # What this console's lowering alone works out from the program (its Lowering::BuildFacts):
        # its art's memos, kept under names of their own.
        def facts = @facts ||= @lowering::BuildFacts.new(self)
      end
    end
  end
end
