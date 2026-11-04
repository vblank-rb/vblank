# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING PLAYSTATION PROGRAM CAN BE ASKED that only the PlayStation's way of
    # keeping things answers — the same questions an Advance reader answers its own way (AdvanceReading).
    #
    # A PlayStation program plays in Beetle PSX (ruby-ps1-emulator), not in libmgba, and the one reader
    # (Verifier) is written over libmgba's core, so it cannot play one yet: a PlayStation program is read
    # back by the lowering's own run (IR::Backends::PS1::HeadlessRun), which plays it in Beetle PSX and
    # compares it with the interpreter. Each question here says so.
    module PS1Reading
      # Lists of 256 colours, kept in video RAM (nothing is drawn with one yet).
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 256)

      # A PlayStation keeps a game's saves on a memory card of 128K (nothing is made to save yet, which
      # Lowering::NOT_LOWERED_YET says).
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x20000, clock_bytes: 0)

      def passes = refuse_ps1_reader!(:passes)
      def sprites(_name = nil) = refuse_ps1_reader!(:sprites)

      private

      def watch_passes! = nil

      def refuse_ps1_reader!(question)
        raise ArgumentError, "A PlayStation program cannot be read back by the Verifier yet, so it cannot say " \
                             "#{question}. Play it with VBlank::IR::Backends::PS1::HeadlessRun instead."
      end
    end
  end
end
