# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Flash
        # What tells a game played as a Flash movie from the same game played on the interpreter:
        # Computer::Differences, in the same words but for what the checked side is called, and with every
        # pixel of every frame played as Flash where a check needs to say where two pictures differ.
        module Differences
          include Computer::Differences

          def lowered_side = "Flash"

          # The game as a movie, played in the harness with its buttons on standard input all at once. There
          # is one way to build it, so the C's build +mode+ plays no part here.
          def run_headless_program(program, _mode, args:, input:)
            movie = Flash.new.build_headless(program)
            Computer::ProgramRun.run(Diagnostics::FlashPlayer.harness_path, args: [movie, "--headless", *args], input: input)
          end
        end

        # A game played as Flash (HeadlessRun), and then the same buttons, frame for frame, played on the
        # interpreter, stopping at the first frame the two disagree on. Everything it compares, and how, is
        # Computer::Check's: the lowerings are held to the interpreter by one check, so none can be held to less.
        #
        #   run = VBlank::IR::Backends::Flash::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # It needs the Flash player (rake compile_flash_player) and Haxe.
        class CheckedRun < HeadlessRun
          include Computer::Check
          include Differences
          extend Differences
        end
      end
    end
  end
end
