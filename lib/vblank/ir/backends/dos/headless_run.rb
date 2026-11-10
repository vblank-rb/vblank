# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # A DOS program played in the emulator with nobody watching, driven and read back through the calls a
        # test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read). Its part so far is
        # the keys: a game's buttons on the keyboard, as Console::DOSHardware::SCAN_CODES says.
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a game names, as ruby-dos-emulator names the keys they are (Core::KEYS).
          KEYS = Ractor.make_shareable({ a: :ctrl, b: :alt, start: :enter, select: :shift, l: :z, r: :x,
                                         up: :up, down: :down, left: :left, right: :right })

          # A keyboard has no motor, so it never runs (Reference#motor_on?).
          def motor_on? = false
        end
      end
    end
  end
end
