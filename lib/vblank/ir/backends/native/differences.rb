# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # What tells a game played as C from the same game played on the interpreter: the
        # comparison every checked run makes, with the program built by zig and run as itself.
        module Differences
          include Computer::Differences

          # +program+ built to run with no window and run with +args+ and +input+, giving back what it
          # printed: the game as C, built the way +mode+ names. JS::Differences runs the game as
          # JavaScript instead, which prints the same lines.
          def run_headless_program(program, mode, args:, input:)
            Computer::ProgramRun.run(Native.new.build_headless(program, mode: mode), args: args, input: input)
          end
        end
      end
    end
  end
end
