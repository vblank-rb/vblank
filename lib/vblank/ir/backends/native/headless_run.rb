# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # A game run as C with no window (runtime/rg_headless.c), driven and read back through
        # the calls a test makes on Backends::Reference. Computer::HeadlessRun reads what the
        # program prints; this supplies the program, built with zig.
        class HeadlessRun < Computer::HeadlessRun
          # Add +seed+ to the game's random numbers once it has set itself up, as the interpreter does
          # (Reference#mix_seed_after_setup). The seed is handed to the program as it starts (`--seed`)
          # and is not in the C, so one program, built and compiled once, plays every seed. Returns self.
          def mix_seed_after_setup(seed)
            @seed_added = seed
            self
          end

          private

          def lowering_name = "the native lowering"
          def skip_helper_name = "skip_on_native"

          def headless_program(program) = Native.new.build_headless(program, seeded: seeded?)

          # A run handed a seed plays a program that has the routine adding it (Computer::Lowering#mix_seed).
          def seeded? = !@seed_added.nil?

          def seed_options = seeded? ? ["--seed", @seed_added.to_s] : []
        end
      end
    end
  end
end
