# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING SUPER NINTENDO CARTRIDGE, answering what the one reader (Verifier) asks of a running
    # cartridge. The Advance and the Color play in libmgba, whose probe (RubyGBAEmulator::Probe) the
    # reader was written over; this plays in bsnes and takes the same calls.
    #
    # Two things differ underneath and stop here. bsnes draws at twice the console's size with
    # blue in the low byte, and the reader takes four bytes a pixel at the console's size with red
    # in the low byte. And the reader gives buttons as the Advance's bits, while bsnes takes names.
    class SNESProbe
      # bsnes's picture is held in 256 × 224, so a whole screen's questions (Emulator.screen_questions)
      # read this as they read any console's.
      def initialize(path, save_dir: nil)
        @core = Emulator.open_snes(path, save_dir: save_dir)
        @battery = Cartridge::SNESROM.battery?(File.binread(path))
        @last_audio = []
      end

      # THE BYTES OF THE .srm FILE AS IT WOULD BE WRITTEN NOW, or nil for a cartridge with no
      # battery. bsnes writes that file only when the cartridge is taken out, so a reader asking
      # while the cartridge runs reads the RAM the file is made from. On a Super FX board that is
      # the chip's RAM, its working memory first (SNESReading.save_file_of gives where the save is).
      def save_memory_file = (@core.save_ram if @battery)

      def width = @core.width
      def height = @core.height

      # +keys+ is a button mask (IR::Buttons.mask).
      def step(frames, keys: 0)
        first, second = IR::Buttons.by_controller(IR::Buttons::HOLDABLE.select { |name| keys.anybits?(IR::Buttons.mask(name)) })
        @core.set_buttons(first)
        @core.set_buttons(second, port: 1)
        @last_audio = Array.new(frames) do
          @core.run_frame
          @core.take_audio.pack("s<*")
        end
      end

      # The picture as four bytes a pixel: red, green, blue and one unused, each five-bit channel
      # widened to eight by repeating its top bits.
      def frame_buffer
        @core.colors.map do |color|
          widened(color & 0x1F) | (widened((color >> 5) & 0x1F) << 8) | (widened((color >> 10) & 0x1F) << 16)
        end.pack("V*")
      end

      # The sound of the last step, a String of samples for each frame of it: 16 bits each, left
      # and right by turns, at SoundRecording's rate for this console.
      def audio_by_frame = @last_audio.dup

      # This probe takes the mix bsnes hands over, with no way to leave one of the eight voices out.
      def hearing(**)
        raise ArgumentError, "This reader cannot play one voice alone on a Super Nintendo cartridge. It records all " \
                             "eight voices together. To fix this, remove `only:` and `without:`."
      end

      def read8(address) = SNESMemory.read8(@core, address)
      def read16(address) = SNESMemory.read16(@core, address)
      def read32(address) = SNESMemory.read32(@core, address)

      def palette = @core.cgram.unpack("v*")

      # The sprite table as bsnes holds it: 544 bytes, four for each of 128 sprites and then
      # the 32 that hold each sprite's top bit of across and its size.
      def sprite_table = @core.oam

      # The console's own memories as bsnes holds them (Verifier#video_ram): the 64K of video
      # memory, the 512 bytes of colour memory, and the sound unit's DSP registers, 128 bytes, as the
      # sound unit's program last wrote them, and the sound chip's own 64K of memory, where its program,
      # its table of recordings and the recordings themselves are kept.
      def video_ram = @core.vram
      def color_ram = @core.cgram
      def sound_registers = @core.dsp_registers
      def sound_ram = @core.apu_ram

      # bsnes here draws every layer into one picture and takes no word to leave one out.
      def showing(**)
        raise ArgumentError, "This reader cannot draw the picture without a layer on a Super Nintendo cartridge. " \
                             "bsnes here draws every layer together."
      end

      # A Super Nintendo cartridge here has no motor.
      def motor_on? = false

      private

      def widened(channel) = (channel << 3) | (channel >> 2)
    end
  end
end
