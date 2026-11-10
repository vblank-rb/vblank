# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # A game run as C with no window (runtime/rg_headless.c), driven and read back through
        # the calls a test makes on Backends::Reference. Computer::HeadlessRun reads what the
        # program prints; this supplies the program, built with zig.
        class HeadlessRun < Computer::HeadlessRun
          private

          def lowering_name = "the native lowering"
          def skip_helper_name = "skip_on_native"

          def headless_program(program) = Native.new.build_headless(program)
        end
      end
    end
  end
end
