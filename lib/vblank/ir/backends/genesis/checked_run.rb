# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A Genesis cartridge played in the emulator (HeadlessRun), and then the same buttons, pass for
        # pass, played on the interpreter — stopping at the first pass the two disagree on, about any
        # variable, any list or pool, or any pixel (CartridgeCheckedRun says how).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Genesis with nothing else changed. The interpreter
        # plays the program on the screen of the console it was built for, and the two pictures are
        # compared over the Genesis's, 320×224, each colour as the three bits of each channel the
        # console keeps (Console::Description#color_bits).
        class CheckedRun < CartridgeCheckedRun
          Moment = HeadlessRun::Moment

          def initialize(save: SaveImage.new)
            super(HeadlessRun, save: save)
          end
        end
      end
    end
  end
end
