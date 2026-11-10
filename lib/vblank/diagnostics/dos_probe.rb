# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING DOS PROGRAM, answering what the one reader (Verifier) asks of a running cartridge. The
    # Advance and the Color play in libmgba, whose probe (RubyGBAEmulator::Probe) the reader was written
    # over; this plays an EXE in DOSBox (ruby-dos-emulator) and takes the same calls, as PS1Probe does for
    # Beetle PSX.
    #
    # What differs underneath stops here. The picture is the one DOSBox shows, as 24-bit colours, and the
    # reader takes four bytes a pixel with red in the low byte. The reader gives keys as one number with a
    # bit each, and the core takes the keys' own names (DOS::HeadlessRun::KEYS lists which is which).
    class DOSProbe
      def initialize(path)
        @core = Emulator.open_dos(path)
        @frames = 0
      end

      # THE PICTURE IS THE SIZE THE CARD SHOWS NOW, which the program sets. Before the first frame DOSBox
      # shows its own start, so the reader asks again after each step.
      def width = @core.picture&.width || 0
      def height = @core.picture&.height || 0

      # +keys+ is a button mask (IR::Buttons.mask).
      def step(frames, keys: 0)
        held = IR::Buttons::HOLDABLE.select { |name| keys.anybits?(IR::Buttons.mask(name)) }
        @core.press(held.filter_map { |button| KEYS[button] })
        frames.times { @core.run_frame }
        @frames = frames
      end

      # The picture as four bytes a pixel: red, green, blue and one unused.
      def frame_buffer
        @core.picture.pixels.map { |pixel| ((pixel >> 16) & 0xFF) | (pixel & 0xFF00) | ((pixel & 0xFF) << 16) }.pack("V*")
      end

      # The sound of the last step, a String for each frame of it: empty, since the build makes none.
      def audio_by_frame = Array.new(@frames) { "".b }

      def read8(offset) = DOSMemory.read8(@core, offset)
      def read16(offset) = DOSMemory.read16(@core, offset)
      def read32(offset) = DOSMemory.read32(@core, offset)

      # A keyboard has no motor.
      def motor_on? = false

      # Shut the core, so the next side of a film starts with only its own emulator running.
      def close
        @core.destroy
        @closed = true
      end

      def closed? = @closed == true

      KEYS = IR::Backends::DOS::HeadlessRun::KEYS
    end
  end
end
