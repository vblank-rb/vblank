# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING GENESIS CARTRIDGE CAN BE ASKED that only the Genesis's way of
    # keeping things answers — the same questions an Advance reader answers its own way
    # (AdvanceReading).
    #
    # A Genesis cartridge plays in Genesis Plus GX (ruby-genesis-emulator), through GenesisProbe: its
    # picture, its work RAM by address, the console's tables, the passes the game finished, from the
    # runtime's own count (CountedPasses), and its sound. It cannot yet say which of the game's
    # sprites each one is; the lowering's own run (IR::Backends::Genesis::HeadlessRun) reads that,
    # and the question here says so.
    module GenesisReading
      include CountedPasses

      # Four lists of sixteen colours, shared by the backgrounds and the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 16)

      # A Genesis cartridge's save memory is the emulator's save RAM, handed over through libretro and
      # not kept in a file, so there is nothing after it: the whole file is the memory (nothing is
      # made to save yet, which Lowering::NOT_LOWERED_YET says).
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x10000, clock_bytes: 0)

      # How far the video chip moves a sprite's place, across and down, so a sprite placed at nought
      # is off the screen.
      SPRITE_PLACE_OFFSET = 128

      def sprites(_name = nil) = refuse_genesis_reader!(:sprites)

      # THE SPRITE TABLE AS BOXES (SpriteBox), one for each entry that reaches the screen, in the
      # order the video chip draws them: from entry 0, each entry naming the next (its link), until
      # one names entry 0. Nothing here needs a build record, so it is how a cartridge with none says
      # where its sprites are.
      #
      # An entry is eight bytes, high byte first: its down (nine bits; a tenth only in the
      # double-height interlaced mode, which this reads as the plain one), a byte whose bits 2-3 are
      # its width and bits 0-1 its height, each one to four tiles less one, the link (seven bits),
      # a word whose low eleven bits are its first tile, and its across (nine bits). Its place is
      # kept plus 128 either way.
      #
      # @return [Array<SpriteBox>]
      def sprite_boxes
        table = sprite_table
        entry_bytes = GenesisProbe::SPRITE_ENTRY_BYTES
        entries = table.bytesize / entry_bytes
        slot = 0
        boxes = []
        entries.times do
          down, size, link, tile, across = table.byteslice(slot * entry_bytes, entry_bytes).unpack("nCCnn")
          boxes << SpriteBox.new(slot: slot, x: (across & 0x1FF) - SPRITE_PLACE_OFFSET,
                                 y: (down & 0x1FF) - SPRITE_PLACE_OFFSET, width: (((size >> 2) & 3) + 1) * 8,
                                 height: ((size & 3) + 1) * 8, tile: tile & 0x7FF)
          slot = link & 0x7F
          break if slot.zero? || slot >= entries
        end
        boxes.select { |box| box.on_screen?(screen_width, screen_height) }
      end

      # The vertical scroll memory and the video chip's 24 registers, as bytes (GenesisProbe).
      #
      # @return [String]
      def scroll_ram
        ensure_rendered!
        @probe.scroll_ram
      end

      def video_registers
        ensure_rendered!
        @probe.video_registers
      end

      # The square voices' and the noise voice's registers, which the FM chip's (Verifier#sound_registers)
      # do not hold: for each of the three square voices the length of its wave then its loudness
      # (fifteen is silent), then the noise voice's setting and its loudness.
      #
      # @return [Array<Integer>]
      def square_voice_registers
        ensure_rendered!
        @probe.square_voice_registers
      end

      private

      def refuse_genesis_reader!(question)
        raise ArgumentError, "The Verifier cannot say #{question} of a Genesis cartridge yet. Play it with " \
                             "VBlank::IR::Backends::Genesis::HeadlessRun instead."
      end
    end
  end
end
