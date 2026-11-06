# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING GAME BOY COLOR CARTRIDGE CAN BE ASKED that only the Color's way
    # of keeping things answers: whose each sprite is, and how many passes of the game loop it
    # finished — the same questions an Advance reader answers its own way (AdvanceReading).
    #
    # The Verifier is the one reader for every console, and a reader over a Color cartridge is
    # given these when it is made (Console::Kit#reading). What only the Advance's cartridge keeps —
    # the processor's registers, the wave voice's pitch, where each routine starts, how often the
    # game read the buttons, the mixer of recordings a Color game cannot have — a Color reader
    # does not have at all.
    #
    # THE SOUND OF THE FIRST FEW FRAMES is the Color's speaker settling after power-on, which the
    # emulator plays as it is: a silent game has some sound energy there that dies away. Ask about
    # the game's own sound after the game has started.
    module ColorReading
      # A Color's colours (see Verifier#palette): eight lists of four for the backgrounds, then eight
      # for the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 32, group: 4)

      # The Color's table of forty sprites, four bytes each, and its scroll and window registers
      # and the register that switches the parts of the picture on, by the manual's names.
      SPRITE_TABLE = 0xFE00
      SPRITE_TABLE_BYTES = 160
      SCROLL_REGISTERS = { SCY: 0xFF42, SCX: 0xFF43, WY: 0xFF4A, WX: 0xFF4B }.freeze
      VIDEO_REGISTERS = { LCDC: 0xFF40 }.freeze

      # THE SOUND CHIP'S REGISTERS, for Verifier#watch_sound: NR10 to NR51, the four voices' and the
      # mixer's. NR52 (the switch for the whole chip) and the wave voice's own memory are left out.
      SOUND_REGISTER_ADDRESSES = (0xFF10..0xFF25)
      def sound_register_addresses = SOUND_REGISTER_ADDRESSES
      # The Color's processor writes a byte at a time.
      def sound_write_mask = 0xFF

      # WHAT THE CONSOLE MAKES ITS PICTURE FROM, other than the tiles' pictures, as
      # AdvanceReading#video_memories gives it: the 64 colours, the sprite table by its bytes,
      # the scroll and the window's place, and the register that switches the parts on.
      def video_memories
        ensure_rendered!
        { colors: palette.each_with_index.to_h { |color, at| [at, color] },
          sprite_table: (0...SPRITE_TABLE_BYTES).to_h { |at| [at, mem8(SPRITE_TABLE + at)] },
          scroll: SCROLL_REGISTERS.transform_values { |address| mem8(address) },
          registers: VIDEO_REGISTERS.transform_values { |address| mem8(address) } }
      end

      # THE SPRITE TABLE AS BOXES (SpriteBox), one for each of the forty entries the console draws, in
      # the table's order. Nothing here needs a build record, so it is how a cartridge with none shows
      # where its sprites are. An entry is four bytes: its down plus 16, its across plus 8, its tile
      # and its settings. So a sprite at nought either way is wholly off the screen, which is how a game
      # hides one. Every entry is 8 wide and 8 tall, or 16 tall when the register LCDC asks for it (bit 2),
      # drawing from an even tile and the one after.
      #
      # @return [Array<SpriteBox>]
      def sprite_boxes
        ensure_rendered!
        tall = mem8(VIDEO_REGISTERS.fetch(:LCDC)).anybits?(TALL_SPRITES_BIT)
        boxes = sprite_table.bytes.each_slice(4).with_index.map do |(down, across, tile, _settings), slot|
          SpriteBox.new(slot: slot, x: across - 8, y: down - 16, width: 8, height: tall ? 16 : 8,
                        tile: tall ? tile & 0xFE : tile)
        end
        boxes.select { |box| box.on_screen?(screen_width, screen_height) }
      end

      TALL_SPRITES_BIT = 0x04

      # A GAME BOY CARTRIDGE WITH A CLOCK CHIP has the emulator write the chip's counters, and the
      # moment it last read them, after the save memory in its file: 48 bytes, the layout other Game
      # Boy emulators write too. What the game saved is the memory before them, in whole banks.
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: Console::GBCHardware::SRAM_BANK_SIZE, clock_bytes: 48)

      include CountedPasses
      include RuntimeLists

      private def list_layout = IR::Backends::GBC::Runtime::Lists

      # A VARIABLE THE GAME SAID IS NARROW is kept in a byte or two here, with the next variable
      # straight after it, so only its own bytes are read, and its sign is put back from the top one.
      private def variable_kept_at(name, address)
        width = @rom.source_program&.kept_width_of(name) or return super
        bytes = IR::KeptWidths::BYTES.fetch(width)
        number = (0...bytes).sum { |i| mem8(address + i) << (8 * i) }
        number >= 1 << ((bytes * 8) - 1) ? number - (1 << (bytes * 8)) : number
      end

      # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter gives them
      # (Reference#sprites): a DrawnSprite for each, with its +name+, +x+, +y+ and +picture+, back
      # to front, where the game put them. Name one and only that sprite's rows come back. The
      # Color's own table of forty eight-pixel pieces does not record whose a piece is, so this reads the
      # list the runtime keeps of what it placed (GBC::Places#drawn_sprite_rows), which the Color's
      # checked run compares with the interpreter after every pass.
      #
      # A cartridge with no build record cannot name whose a sprite is, and says so.
      #
      # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
      # @return [Array<DrawnSprite>]
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn, method(:mem8))
        name ? @drawn.rows_named(rows, name) : rows
      end
    end
  end
end
