# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING SUPER NINTENDO CARTRIDGE CAN BE ASKED that only the Super
    # Nintendo's way of keeping things answers — the same questions an Advance reader answers its own
    # way (AdvanceReading).
    #
    # A Super Nintendo cartridge plays in bsnes (ruby-snes-emulator), through SNESProbe. Its picture,
    # memory, sprites, passes and sound are read as the other consoles' are.
    module SNESReading
      include CountedPasses
      include RuntimeLists

      private def list_layout = IR::Backends::SNES::Runtime::Lists

      # Eight lists of sixteen colours for the backgrounds, then eight for the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 128, group: 16)

      # bsnes keeps a cartridge's battery-backed RAM in a .srm file of its own, nothing after it,
      # as big as the header says: the size the header's byte says for the save memory a game has
      # (IR::Backends::SNES::Runtime::Saving), worked out the way the header is written
      # (Cartridge::SNESROM.size_byte), so the two cannot differ. test_snes_saves.rb holds it to a
      # built header and to the save RAM bsnes gives the cartridge.
      SAVE_FILE = Verifier::SaveFileLayout.new(
        whole: Cartridge::SNESROM.bytes_of_size_byte(Cartridge::SNESROM.size_byte(IR::Backends::SNES::Runtime::Saving::SIZE)),
        clock_bytes: 0
      )

      # A Super FX cartridge that saves has 128K of the chip's RAM, and bsnes keeps all of it in
      # the file: the chip's working 64K, then the save (Cartridge::SNESROM::SUPER_FX).
      SUPER_FX_SAVE_FILE = Verifier::SaveFileLayout.new(whole: SAVE_FILE.whole, clock_bytes: 0,
                                                        memory_at: Cartridge::SNESROM::SUPER_FX.save_offset)

      # The layout of the save file of the cartridge whose bytes are +bytes+, read from its header.
      def self.save_file_of(bytes) = Cartridge::SNESROM.save_offset_of(bytes).zero? ? SAVE_FILE : SUPER_FX_SAVE_FILE

      # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter says them (Reference#sprites),
      # from the list the runtime keeps of what it placed, which the checked run compares with the
      # interpreter after every pass. See ColorReading#sprites.
      #
      # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
      # @return [Array<DrawnSprite>]
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn, method(:mem16))
        name ? @drawn.rows_named(rows, name) : rows
      end
    end
  end
end
