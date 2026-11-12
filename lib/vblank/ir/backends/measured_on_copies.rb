# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # HOW MANY BYTES A RUN OF STATEMENTS COMES TO, made on copies of what the lowering holds and
      # thrown away: the #bytes_of RoutineCuts asks a lowering for when a routine is too big for a
      # bank. Mixed into a cartridge lowering that makes each statement with #statement into the
      # assembler in @asm, numbers its labels from @labels and names the routine it is making in
      # @routine, and keeps what it holds in a LOWERING_STATE (LoweringState#on_copies).
      #
      # The lowering gives #measuring_assembler, a fresh assembler of its processor's that the run
      # is made into. A lowering that cuts routines and measures its own way is in OWN_WAYS, with
      # its reason; test_measured_on_copies.rb holds every lowering that cuts routines to one or
      # the other.
      module MeasuredOnCopies
        # The lowerings that measure a run of statements their own way, by the lowering's name.
        OWN_WAYS = Ractor.make_shareable(
          {
            "GBC" => "A Color routine gathers constants and data beside its code, which a measurement counts, " \
                     "and GBC::Lowering#bytes_of notes each statement's size for the cut as it is made " \
                     "(#statement_measured), so cutting measures nothing again. It reserves no work memory " \
                     "while it measures, so it needs no copies of the lowering's state."
          }
        )

        def bytes_of(list)
          self.class::LOWERING_STATE.on_copies(self) do
            @asm = measuring_assembler
            @routine = "measuring"
            @labels = 0
            list.each { |node| statement(node) }
            @asm.here
          end
        end
      end
    end
  end
end
