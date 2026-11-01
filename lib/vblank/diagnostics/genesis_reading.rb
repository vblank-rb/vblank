# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING GENESIS CARTRIDGE CAN BE ASKED that only the Genesis's way of
    # keeping things answers — the same questions an Advance reader answers its own way
    # (AdvanceReading).
    #
    # A Genesis cartridge plays in Genesis Plus GX (ruby-genesis-emulator), not in libmgba, and the
    # one reader (Verifier) is written over libmgba's core, so it cannot play one yet: a Genesis
    # cartridge is read back by the lowering's own run (IR::Backends::Genesis::HeadlessRun), which
    # plays it in Genesis Plus GX and compares it with the interpreter. Each question here says so.
    module GenesisReading
      # Four lists of sixteen colours, shared by the backgrounds and the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 16)

      # A Genesis cartridge's save memory is the emulator's save RAM, handed over through libretro and
      # not kept in a file, so there is nothing after it: the whole file is the memory (nothing is
      # made to save yet, which Lowering::NOT_LOWERED_YET says).
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x10000, clock_bytes: 0)

      def passes = refuse_genesis_reader!(:passes)
      def sprites(_name = nil) = refuse_genesis_reader!(:sprites)

      private

      def watch_passes! = nil

      def refuse_genesis_reader!(question)
        raise ArgumentError, "A Genesis cartridge cannot be read back by the Verifier yet, so it cannot say " \
                             "#{question}. Play it with VBlank::IR::Backends::Genesis::HeadlessRun instead."
      end
    end
  end
end
