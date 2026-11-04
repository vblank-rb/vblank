# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A PlayStation program played in the emulator (HeadlessRun), and then the same buttons, pass for
        # pass, played on the interpreter — stopping at the first pass the two disagree on, about any
        # variable, any list or pool, or any pixel (CartridgeCheckedRun says how).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one of
        # these instead and play its game on a PlayStation with nothing else changed. The interpreter plays
        # the program on the PlayStation's screen, 320×240, and the two pictures are compared over it.
        class CheckedRun < CartridgeCheckedRun
          def initialize(save: SaveImage.new)
            super(HeadlessRun, save: save)
          end
        end
      end
    end
  end
end
