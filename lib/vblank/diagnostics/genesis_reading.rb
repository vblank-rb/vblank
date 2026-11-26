# frozen_string_literal: true

module VBlank
  module Diagnostics
    # What a reader over a running Genesis cartridge can be asked that only the Genesis's way of
    # keeping things answers — the same questions an Advance reader answers its own way
    # (AdvanceReading).
    #
    # A Genesis cartridge plays in Genesis Plus GX (ruby-genesis-emulator), through GenesisProbe: its
    # picture, its work RAM by address, the console's tables, the passes the game finished, from the
    # runtime's own count (CountedPasses), its sound, and where each sprite is, from the rows the
    # runtime keeps.
    module GenesisReading
      include CountedPasses
      include RuntimeLists

      private def list_layout = IR::Backends::Genesis::Runtime::Lists

      # The 68000 keeps a number's high byte first, in a list's header and its slots alike.
      private def big_endian? = true

      # Four lists of sixteen colours, shared by the backgrounds and the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 16)

      # A Genesis cartridge's save memory is the emulator's save RAM, handed over through libretro. The
      # emulator's gem keeps it in a file as a frontend does (RubyGenesisEmulator::Core#destroy): 64K, the
      # save memory on its odd bytes, and nothing after it.
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x10000, clock_bytes: 0, odd_bytes: true)

      # How far the video chip moves a sprite's place, across and down, so a sprite placed at nought
      # is off the screen.
      SPRITE_PLACE_OFFSET = 128

      # What the console makes its picture from, other than the tiles' pictures, as
      # AdvanceReading#video_memories gives it: the 64 colours, the sprite table by its bytes, the
      # vertical scroll memory by its words (two for each pair of columns, one for each of the two
      # scrolling layers), and the video chip's 24 registers by their numbers, which the emulator
      # keeps though the console cannot read them back. How far each layer is scrolled across is a
      # table in video memory a register points at, among the tiles' pictures, so it is not here.
      def video_memories
        ensure_rendered!
        { colors: palette.each_with_index.to_h { |color, at| [at, color] },
          sprite_table: @probe.sprite_table.bytes.each_with_index.to_h { |byte, at| [at, byte] },
          scroll: @probe.scroll_ram.unpack("n*").each_with_index.to_h { |word, at| [at, word] },
          registers: @probe.video_registers.bytes.each_with_index.to_h { |byte, at| [at, byte] } }
      end

      # The sprites the game placed in its last pass, as the interpreter gives them (Reference#sprites),
      # from the rows the runtime keeps of what it placed (IR::Backends::Genesis::Places#drawn_sprite_rows),
      # read off work RAM. See ColorReading#sprites.
      #
      # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
      # @return [Array<DrawnSprite>]
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn) { |address| mem16(address) }
        name ? @drawn.rows_named(rows, name) : rows
      end

      def music_playing = refuse_genesis_reader!(:music_playing)

      # The sprite table as boxes (SpriteBox), one for each entry that reaches the screen, in the
      # order the video chip draws them: from entry 0, each entry naming the next (its link), until
      # one names entry 0. Nothing here needs a build record, so it is how a cartridge with none shows
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

      # Every write the cartridge makes to its sound chips from now on, a test's way to see each note a game
      # starts (Verifier#watch_sound): after each #step, #sound_writes lists what that step wrote to the FM chip
      # and to the square voices, a value written twice included, but for the DAC's samples and the timers,
      # which a recording makes every sample. Gives back what the FM chip's registers hold now, by number.
      #
      # @return [Hash{Integer => Integer}]
      def watch_sound
        ensure_rendered!
        @probe.take_sound_writes # starts the log; what it answers is nothing
        @sound_writes_seen = 0
        @sound_writes = []
        sound_registers.bytes.each_with_index.to_h { |value, register| [register, value] }
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

      # The writes the last step made, as SoundWrites: an FM write at its register, a square voice's at the
      # chip's one address.
      def take_sound_writes
        dropped, writes = @probe.take_sound_writes
        if dropped.positive?
          raise ArgumentError, "More than a million writes to the sound chips came in one step, so some are not " \
                               "listed. To fix this, step fewer frames at a time."
        end

        @sound_writes = writes.map do |chip, register, value|
          Verifier::SoundWrite.new(address: chip == :fm ? register : Console::GenesisHardware::PSG, value: value, chip: chip)
        end
      end

      def refuse_genesis_reader!(question)
        raise ArgumentError, "The Verifier cannot say #{question} of a Genesis cartridge yet. Play it with " \
                             "VBlank::IR::Backends::Genesis::HeadlessRun instead."
      end
    end
  end
end
