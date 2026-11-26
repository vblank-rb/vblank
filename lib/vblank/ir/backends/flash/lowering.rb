# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Flash
        # One program, written out as Haxe. Make one per program and ask for #text_and_gaps.
        #
        # It is the shared lowering's own, printed as Haxe. Computer::Lowering turns a program into a small
        # tree of statements (Computer::Statements): globals, routines, tables of numbers, and calls into a
        # runtime — never an operator on a number, since every one goes through a function that does what
        # IR::Int32 does. The same tree is printed as Haxe here (Printer) and played by a runtime written in
        # Haxe (runtime/), which is the JavaScript runtime written again. What a program says — the art
        # worked out in Ruby, which kinds are not lowered, what is refused — is all Computer::Lowering's.
        class Lowering < Computer::Lowering
          # The program as the body of the game's class, and the runtime functions it calls that the
          # runtime it is to run with does not have yet (+defined+ is every function the runtime and the
          # driver define), each said in a few words.
          def text_and_gaps(defined)
            refuse_unlowered_kinds!
            items = top_level
            printer = Printer.new
            text = printer.print_file(items)
            [text, printer.called.to_a - printer.own.to_a - defined + features_not_made]
          end

          # The console the game is played as, in the numbers the runtime needs from it, as constants ahead
          # of the runtime: the size of its screen, the cycles its clock counts a second, and the rest
          # (Computer::ConsoleNumbers), and the state file's (Computer::StateFile).
          def console_text
            Computer::ConsoleNumbers.values(@program.described_console).map do |name, value|
              "static inline var #{name}:Int = #{Computer::ConsoleNumbers.as_number(value)};\n"
            end.join + Computer::StateFile.hx_text(@program)
          end

          private

          def build_name = "the Flash build"

          # The runtime features the program's steps need that have no Haxe file yet, said as the feature.
          def features_not_made
            runtime_features.reject { |feature| File.exist?(feature.file("hx")) }.map { |feature| "the #{feature.name} feature" }
          end
        end
      end
    end
  end
end
