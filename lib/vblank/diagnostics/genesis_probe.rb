# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING SEGA GENESIS CARTRIDGE, answering what the one reader (Verifier) asks of a running
    # cartridge. The Advance and the Color play in libmgba, whose probe (RubyGBAEmulator::Probe) the
    # reader was written over; this plays in Genesis Plus GX (ruby-genesis-emulator) and takes the same
    # calls, as SNESProbe does for bsnes.
    #
    # What differs underneath stops here. The core hands each pixel over as the console's own colour,
    # three bits a channel, and the reader takes four bytes a pixel with red in the low byte. The reader
    # gives buttons as the Advance's bits, and the core takes the pad's names. And the 68000 keeps a
    # number high byte first, so memory is read that way: an address is one in work RAM, $FF0000 to
    # $FFFFFF, where a game keeps everything it changes.
    class GenesisProbe
      # Where the 68000 sees work RAM, and how big it is.
      WORK_RAM = Console::GenesisHardware::WRAM
      WORK_RAM_BYTES = Console::GenesisHardware::WRAM_SIZE

      # The video chip's registers that hold where the sprite table is in video memory (5) and how wide
      # the screen is (12): a screen 320 wide has 80 entries of eight bytes, one 256 wide has 64.
      # Register 5 holds the table's place in 512-byte steps; on a wide screen its lowest bit is
      # ignored, as the table must start on a 1K boundary there.
      SPRITE_TABLE_REGISTER = 5
      SPRITE_TABLE_STEP_BITS = 9
      SCREEN_WIDTH_REGISTER = 12
      WIDE_SCREEN_BITS = 0x81
      SPRITE_ENTRY_BYTES = 8
      WIDE_SCREEN_SPRITE_ENTRIES = 80
      NARROW_SCREEN_SPRITE_ENTRIES = 64

      def initialize(path, save_dir: nil)
        @core = Emulator.open_genesis(path, save_dir: save_dir)
        @last_audio = []
      end

      def width = @core.width
      def height = @core.height

      # +keys+ is a button mask (IR::Buttons.mask). A Genesis has one controller here, and the
      # reader refuses a second player's buttons before they reach this.
      def step(frames, keys: 0)
        held = IR::Buttons::HOLDABLE.select { |name| keys.anybits?(IR::Buttons.mask(name)) }
        @core.set_buttons(IR::Buttons.by_controller(held).first & PAD_BUTTONS)
        @last_audio = Array.new(frames) do
          @core.run_frame
          @core.take_audio.pack("s<*")
        end
      end

      # The picture as four bytes a pixel: red, green, blue and one unused, each of the console's
      # three-bit channels widened to five, as every console's colours are given, and then to eight.
      def frame_buffer
        @core.colors.map { |color| PIXELS.fetch(color) }.pack("V*")
      end

      # The sound of the last step, a String of samples for each frame of it: 16 bits each, left and
      # right by turns.
      def audio_by_frame = @last_audio.dup

      def read8(address) = @core.wram_read8(work_ram_offset(address))
      def read16(address) = @core.wram_read16(work_ram_offset(address))
      def read32(address) = @core.wram_read32(work_ram_offset(address))

      # The 64 colours as 15-bit colours, each channel's three bits widened to five.
      def palette = @core.color_ram.map { |color| COLORS.fetch(color) }

      # The console's own memories (Verifier#video_ram), high byte first as the 68000 keeps them: the
      # 64K of video memory, the colour memory as 64 words the way the console's code writes them
      # (0000 BBB0 GGG0 RRR0), the sprite table where register 5 puts it, and the FM chip's registers
      # as the cartridge last wrote them, 256 for its first three voices then 256 for the other three.
      def video_ram = @core.vram
      def color_ram = @core.cram.unpack("v*").pack("n*")
      def sound_registers = @core.fm_registers

      def sprite_table
        registers = @core.vdp_registers
        wide = registers[SCREEN_WIDTH_REGISTER].anybits?(WIDE_SCREEN_BITS)
        from = (registers[SPRITE_TABLE_REGISTER] & (wide ? 0x7E : 0x7F)) << SPRITE_TABLE_STEP_BITS
        @core.vram.byteslice(from, (wide ? WIDE_SCREEN_SPRITE_ENTRIES : NARROW_SCREEN_SPRITE_ENTRIES) * SPRITE_ENTRY_BYTES)
      end

      # What only the Genesis has (GenesisReading): the square voices' and the noise voice's
      # registers (RubyGenesisEmulator::Core#psg_registers), the vertical scroll memory (80 bytes, two
      # for each pair of columns, high byte first like the memories above; the core keeps it low byte
      # first), and the video chip's 24 registers, a byte each.
      def square_voice_registers = @core.psg_registers
      def scroll_ram = @core.vsram.unpack("v*").pack("n*")
      def video_registers = @core.vdp_registers.pack("C*")

      # Genesis Plus GX here mixes every voice together and draws every layer together.
      def hearing(**)
        raise ArgumentError, "This reader cannot play one voice alone on a Genesis cartridge. It records every " \
                             "voice together. To fix this, remove `only:` and `without:`."
      end

      def showing(**)
        raise ArgumentError, "This reader cannot draw the picture without a layer on a Genesis cartridge. " \
                             "Genesis Plus GX here draws every layer together. To fix this, remove `only:` and " \
                             "`without:`."
      end

      # A Genesis pad has no motor.
      def motor_on? = false

      # Shut the core, so the next side of a film starts with only its own emulator running.
      def close
        @core.destroy
        @closed = true
      end

      def closed? = @closed == true

      PAD_BUTTONS = Console::GENESIS.buttons

      # The console's 9-bit colours (red in the low three bits, then green, then blue) as 15-bit
      # colours, and as the four bytes of a pixel of the reader's picture.
      COLORS = Ractor.make_shareable(Array.new(512) do |color|
        Array.new(3) { |channel| Console::GenesisHardware.widen((color >> (channel * 3)) & 7) << (channel * 5) }.sum
      end)
      PIXELS = Ractor.make_shareable(COLORS.map do |color|
        Array.new(3) { |channel| ((color >> (channel * 5)) & 0x1F).then { |level| (level << 3) | (level >> 2) } << (channel * 8) }.sum
      end)

      private

      # Where +address+ is in work RAM. An address anywhere else (the cartridge, the chips' ports) is
      # refused: the core reads work RAM alone, by its low sixteen bits, so another address would read
      # a byte of work RAM and give it as the answer.
      def work_ram_offset(address)
        return address - WORK_RAM if address.between?(WORK_RAM, WORK_RAM + WORK_RAM_BYTES - 1)

        raise ArgumentError, "#{format('$%06X', address)} is not in the Genesis's work RAM. This reader reads work RAM, " \
                             "#{format('$%06X', WORK_RAM)} to #{format('$%06X', WORK_RAM + WORK_RAM_BYTES - 1)}. " \
                             "To fix this, give an address in work RAM."
      end
    end
  end
end
