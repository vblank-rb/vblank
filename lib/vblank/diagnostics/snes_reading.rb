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

      # WHAT THE CONSOLE MAKES ITS PICTURE FROM, other than the tiles' pictures, as
      # AdvanceReading#video_memories gives it: the 256 colours, and the sprite table by its
      # bytes. The Super Nintendo's scroll and video registers cannot be read back on the
      # console, and bsnes does not hand them over here, so they are not among them.
      def video_memories
        ensure_rendered!
        { colors: palette.each_with_index.to_h { |color, at| [at, color] },
          sprite_table: @probe.sprite_table.bytes.each_with_index.to_h { |byte, at| [at, byte] } }
      end

      # THE SPRITE TABLE AS BOXES (SpriteBox), one for each of the 128 entries that reaches the screen,
      # in the table's order. Nothing here needs a build record, so it is how a cartridge with none
      # shows where its sprites are.
      #
      # +sizes+ is [small, large], each [width, height]: the two sizes the game set the register
      # OBSEL to, and an entry's bit in the upper table marks which of the two it is. bsnes here does
      # not hand OBSEL over, so the game gives it ([[8, 8], [16, 16]] is OBSEL's sizes 0, and what
      # VBlank's own build sets). An entry's across is nine bits, its top bit in the upper table, and
      # wraps at 512; its down wraps at 256. The console draws a sprite a line below its down, and
      # its picture starts a line down too, so the down kept is the row of the picture it is on. The
      # tile number is nine bits, its top bit the low bit of the entry's fourth byte.
      #
      # @return [Array<SpriteBox>]
      def sprite_boxes(sizes: nil)
        refuse_sprite_sizes_missing!(sizes)
        table = sprite_table
        upper = table.byteslice(SPRITE_ENTRIES * 4, SPRITE_ENTRIES / 4).bytes
        boxes = Array.new(SPRITE_ENTRIES) do |slot|
          across, down, tile, attributes = table.byteslice(slot * 4, 4).bytes
          bits = (upper[slot / 4] >> ((slot % 4) * 2)) & 0b11
          width, height = sizes.fetch(bits[1])
          SpriteBox.new(slot: slot, x: SpriteBox.wrapped(across | (bits[0] << 8), width, 512),
                        y: SpriteBox.wrapped(down, height, 256), width: width, height: height,
                        tile: tile | ((attributes & 1) << 8))
        end
        boxes.select { |box| box.on_screen?(screen_width, screen_height) }
      end

      SPRITE_ENTRIES = 128

      private def refuse_sprite_sizes_missing!(sizes)
        return if sizes.is_a?(Array) && sizes.size == 2 && sizes.all? { |size| size.is_a?(Array) && size.size == 2 }

        raise ArgumentError, "A Super Nintendo cartridge draws its sprites in two sizes that the game sets, and this " \
                             "reader cannot read them. To fix this, give the two sizes, small then large, like " \
                             "`sprite_boxes(sizes: [[8, 8], [16, 16]])`."
      end

      # bsnes keeps a cartridge's battery-backed RAM in a .srm file of its own, nothing after it,
      # as big as the header gives: the size the header's byte gives for the save memory a game has
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

      # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter gives them (Reference#sprites),
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

      # WHICH SONG IS PLAYING NOW, by its name, or nil for none (Reference#music_playing): the two
      # bytes the player keeps the song it is on in (SNES::Runtime::Music::PLAYING), its place in the
      # order declared (IR::Tunes.song_numbered), as the frames played so far left it. See
      # ColorReading#music_playing.
      def music_playing
        refuse_missing_build_record!("which songs it plays")
        place = @rom.built.runtime[IR::Backends::SNES::Runtime::Music::PLAYING] or return nil
        IR::Tunes.song_numbered(@rom.source_program, mem16(place))
      end
    end
  end
end
