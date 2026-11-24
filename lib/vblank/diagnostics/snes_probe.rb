# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A running Super Nintendo cartridge, answering what the one reader (Verifier) asks of a running
    # cartridge. The Advance and the Color play in libmgba, whose probe (RubyGBAEmulator::Probe) the
    # reader was written over; this plays in bsnes and takes the same calls.
    #
    # Two things differ underneath and stop here. bsnes draws at twice the console's size with
    # blue in the low byte, and the reader takes four bytes a pixel at the console's size with red
    # in the low byte. And the reader gives buttons as the Advance's bits, while bsnes takes names.
    class SNESProbe
      # bsnes's picture is held in 256 × 224, so a whole screen's questions (Emulator.screen_questions)
      # read this as they read any console's.
      #
      # +multitap+ plugs a Super Multitap into the second port before the first frame, as a person
      # playing with four would have (RubySNESEmulator::Core#plug_in_multitap).
      def initialize(path, save_dir: nil, multitap: false)
        @core = Emulator.open_snes(path, save_dir: save_dir)
        @core.plug_in_multitap if multitap
        @battery = Cartridge::SNESROM.battery?(File.binread(path))
        @last_audio = []
        @voices_chosen = false
      end

      # The bytes of the .srm file as it would be written now, or nil for a cartridge with no
      # battery. bsnes writes that file only when the cartridge is taken out, so a reader asking
      # while the cartridge runs reads the RAM the file is made from. On a Super FX board that is
      # the chip's RAM, its working memory first (SNESReading.save_file_of gives where the save is).
      def save_memory_file = (@core.save_ram if @battery)

      def width = @core.width
      def height = @core.height

      # +keys+ is a button mask (IR::Buttons.mask). The second player's go to the second port, and
      # the third and fourth players' to the next plugs of a Super Multitap there, as
      # IR::Backends::SNES::HeadlessRun hands them over. Without a tap (+multitap+), the second
      # port has a plain controller, and the third and fourth players' buttons reach nothing.
      def step(frames, keys: 0)
        held = IR::Buttons::HOLDABLE.select { |name| keys.anybits?(IR::Buttons.mask(name)) }
        IR::Buttons.by_controller(held, controllers: Console::SUPER_NINTENDO.controllers)
                   .each_with_index { |buttons, port| @core.set_buttons(buttons, port: port) }
        @last_audio = Array.new(frames) do
          @core.run_frame
          @core.take_audio.pack("s<*")
        end
      end

      # The picture as four bytes a pixel: red, green, blue and one unused, each five-bit channel
      # widened to eight by repeating its top bits.
      #
      # The core hands back the same list of colours while the picture has not changed, and then the
      # bytes made from it last time are the answer again. They are frozen, as the reader keeps them.
      def frame_buffer
        colors = @core.colors
        return @frame_buffer if @frame_buffer_of.equal?(colors)

        @frame_buffer_of = colors
        @frame_buffer = SNESProbe.picture_bytes(colors).freeze
      end

      # The four bytes of each of +colors+ (the console's 15-bit colours), one after another. Each
      # pixel is a lookup that Array#values_at makes in C, not a Ruby block run for every pixel,
      # which cost more than a frame of the console. Public for the probe's test, which holds every
      # colour to its answer key.
      def self.picture_bytes(colors) = PIXEL_BYTES.values_at(*colors).join

      # Each five-bit channel widened to eight by repeating its top bits.
      def self.widened(channel) = (channel << 3) | (channel >> 2)

      # The four bytes of a pixel of the reader's picture for each of the 32768 colours.
      PIXEL_BYTES = Ractor.make_shareable(Array.new(0x8000) do |color|
        Array.new(3) { |channel| widened((color >> (channel * 5)) & 0x1F) }.pack("C3x")
      end)

      # The sound of the last step, a String of samples for each frame of it: 16 bits each, left
      # and right by turns, at SoundRecording's rate for this console.
      def audio_by_frame = @last_audio.dup

      # The sound chip's eight voices, by the numbers its registers give them (fullsnes, "SNES APU
      # DSP Voices"): :voice0 to :voice7.
      VOICE_NAMES = Ractor.make_shareable((0..7).map { |voice| :"voice#{voice}" })

      def channels = VOICE_NAMES

      # Hear only the voices +only+ names, or every voice but those +without+ names, from the next
      # sample on, with a block for the length of the block. The others are left out where the chip
      # adds each voice into the mix, and go on running (RubySNESEmulator::Core#silence_voices), so
      # this can change at any frame, and a voice heard again sounds as if it had never been left out.
      def hearing(only: nil, without: nil)
        if only.nil? == without.nil?
          raise ArgumentError, "hearing must have only: or without:. only: keeps the voices you name and leaves out " \
                               "the rest. without: leaves out the voices you name."
        end
        named = Array(only || without)
        unknown = named - channels
        unless unknown.empty?
          raise ArgumentError, "A Super Nintendo has no voice #{unknown.join(', ')}. Its voices are #{channels.join(', ')}."
        end

        before = @core.silent_voices
        @voices_chosen = true
        silent = only ? channels - named : named
        @core.silence_voices(silent.map { |voice| channels.index(voice) })
        return self unless block_given?

        begin
          yield
        ensure
          @core.silence_voices(before)
        end
      end

      def read8(address) = SNESMemory.read8(@core, address)
      def read16(address) = SNESMemory.read16(@core, address)
      def read32(address) = SNESMemory.read32(@core, address)
      def write32(address, value) = SNESMemory.write32(@core, address, value)

      # The console's whole state, written to the file +path+ in bsnes's own format, and put back
      # from one (Verifier#save_state, #load_state).
      def save_state(path) = File.binwrite(path, @core.serialize)

      # bsnes clears the byte that silences voices as it loads a state, so the voices this reader
      # was told to hear (#hearing) are chosen again after: which voices are heard is the reader's
      # choice, never the state's. A reader never told hears every voice and asks nothing of the
      # core, which an older core cannot answer.
      def load_state(path)
        silent = @core.silent_voices if @voices_chosen
        @core.unserialize(File.binread(path))
        @core.silence_voices(silent) if silent
      end

      def palette = @core.cgram.unpack("v*")

      # The sprite table as bsnes holds it: 544 bytes, four for each of 128 sprites and then
      # the 32 that hold each sprite's top bit of across and its size.
      def sprite_table = @core.oam

      # The two sizes the cartridge's sprites come in, small then large, each [width, height], from
      # OBSEL as the game last wrote it (Console::SNESHardware::OBSEL_SPRITE_SIZES).
      def sprite_sizes
        hardware = Console::SNESHardware
        hardware::OBSEL_SPRITE_SIZES.fetch(@core.obsel >> hardware::OBSEL_SIZE_SHIFT)
      end

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

      # Shut the core now (Verifier#close), not when Ruby collects it: bsnes writes the cartridge's
      # save as it shuts, and the copy of the core goes back for the next console to use.
      def close
        @core.destroy
        @closed = true
      end

      def closed? = @closed == true
    end
  end
end
