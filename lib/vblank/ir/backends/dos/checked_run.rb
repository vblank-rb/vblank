# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # A DOS program played in the emulator (HeadlessRun), and then the same buttons, pass for pass, played
        # on the interpreter — stopping at the first pass the two disagree on, about any variable, any list or
        # pool, or any pixel (CartridgeCheck says how).
        class CheckedRun < HeadlessRun
          include CartridgeCheck
        end
      end
    end
  end
end
