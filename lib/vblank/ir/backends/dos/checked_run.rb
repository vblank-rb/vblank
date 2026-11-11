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

          private

          # The same clock on both sides, started at the same moment (#clock_at), and one the interpreter is
          # told of even where the run was not, since a PC always has one.
          def prepare_interpreter(interpreter)
            interpreter.clock_at(clock_given, set: clock_given_set?, keeps_date: true)
          end
        end
      end
    end
  end
end
