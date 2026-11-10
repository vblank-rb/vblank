# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # A game's program as every build for a computer starts from it: checked the way a cartridge
        # build checks it, every guardrail on, with no cartridge made (Cartridge::Game#checked_program).
        # So nothing the console's answers refuse can be built for a computer instead. What only the
        # console's own code generator refuses (a cartridge too full, a part it does not make yet) is
        # found by building the cartridge, which costs a big game most of a minute, so a computer's
        # build leaves it to the cartridge build.
        module CheckedProgram
          module_function

          # Guardrail warnings are printed to +err+, as the cartridge build prints them.
          #
          # The program is for +console+, one the game names, and the first it names when that is left
          # out. It is built as that console: the runtime's screen is its size (ConsoleNumbers), and the
          # program does what the game does on it. +pack_at_start+ leaves the game's data pack out
          # (Cartridge::Options).
          def build(game, console: nil, settings: {}, err: $stderr, progress: Messages::Progress.silent,
                    pack_at_start: false)
            game.checked_program(err: err, progress: progress, settings: settings, console: console || game.consoles.first,
                                 pack_at_start: pack_at_start)
          end
        end
      end
    end
  end
end
