# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING DOS PROGRAM CAN BE ASKED that only DOS's way of keeping things answers —
    # the same questions an Advance reader answers its own way (AdvanceReading).
    #
    # A DOS program plays in DOSBox (ruby-dos-emulator), and the one reader (Verifier) plays it there
    # through DOSProbe: its picture, its memory by offset, and keys held, which is what a film asks, and the
    # passes the game finished, from the runtime's own count (CountedPasses), as a profile reads them. Whose
    # each sprite is it cannot answer yet; the lowering's own run (IR::Backends::DOS::HeadlessRun) reads that,
    # and the question here says so.
    module DOSReading
      include CountedPasses

      # The card's palette of 256 colours, kept in the card.
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 256)

      # A DOS game keeps its saves in a file beside the program (nothing is made to save yet, which
      # Lowering::NOT_LOWERED_YET says).
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x10000, clock_bytes: 0)

      def sprites(_name = nil) = refuse_dos_reader!(:sprites)

      # No song is ever playing: the build refuses a game that plays one, which Lowering::NOT_LOWERED_YET
      # says (Reference#music_playing).
      def music_playing = nil

      private

      def refuse_dos_reader!(question)
        raise ArgumentError, "The Verifier cannot read this back from a DOS program yet, so it cannot say " \
                             "#{question}. Play it with VBlank::IR::Backends::DOS::HeadlessRun instead."
      end
    end
  end
end
