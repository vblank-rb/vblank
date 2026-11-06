# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING PLAYSTATION PROGRAM, answering what the one reader (Verifier) asks of a running
    # cartridge. The Advance and the Color play in libmgba, whose probe (RubyGBAEmulator::Probe) the
    # reader was written over; this plays a PS-X EXE in Beetle PSX (ruby-ps1-emulator) and takes the
    # same calls, as SNESProbe does for bsnes.
    #
    # What differs underneath stops here. The picture is read from video RAM where the graphics chip is
    # told to show it, at the size it shows, as 15-bit colours, and the reader takes four bytes a pixel
    # with red in the low byte. The reader gives buttons as one number with a bit each, and the core takes the pad's own
    # names (PS1::HeadlessRun::PAD_BUTTONS lists which is which). And the build makes no sound yet, so
    # every frame's sound is silence.
    class PS1Probe
      def initialize(path, save_dir: nil)
        @core = Emulator.open_ps1(path, save_dir: save_dir)
        @frames = 0
      end

      # THE PICTURE IS THE SIZE THE GRAPHICS CHIP SHOWS NOW, which the program sets: 320 × 240 for every
      # screen VBlank's build makes, and whatever another program chose. Before the first frame the chip
      # is still in the mode the BIOS left, 256 wide, so the reader asks again after each step.
      def width = @core.width
      def height = @core.height

      # +keys+ is a button mask (IR::Buttons.mask).
      def step(frames, keys: 0)
        held = IR::Buttons::HOLDABLE.select { |name| keys.anybits?(IR::Buttons.mask(name)) }
        IR::Buttons.by_controller(held).each_with_index do |buttons, port|
          @core.set_buttons(buttons.filter_map { |button| PAD_BUTTONS[button] }, port: port)
        end
        frames.times { @core.run_frame }
        @frames = frames
      end

      # The picture as four bytes a pixel: red, green, blue and one unused, each five-bit channel
      # widened to eight by repeating its top bits: the picture the chip shows, as the core reads it
      # (RubyPS1Emulator::Core#colors).
      def frame_buffer
        @core.colors.map do |color|
          widened(color & 0x1F) | (widened((color >> 5) & 0x1F) << 8) | (widened((color >> 10) & 0x1F) << 16)
        end.pack("V*")
      end

      # The sound of the last step, a String for each frame of it: empty, since the build makes none.
      def audio_by_frame = Array.new(@frames) { "".b }

      def read8(address) = PS1Memory.read8(@core, address)
      def read16(address) = PS1Memory.read16(@core, address)
      def read32(address) = PS1Memory.read32(@core, address)

      # The pad the build reads has no motor.
      def motor_on? = false

      # Shut the core, so the next side of a film starts with only its own emulator running.
      def close
        @core.destroy
        @closed = true
      end

      def closed? = @closed == true

      PAD_BUTTONS = IR::Backends::PS1::HeadlessRun::PAD_BUTTONS

      private

      def widened(channel) = (channel << 3) | (channel >> 2)
    end
  end
end
