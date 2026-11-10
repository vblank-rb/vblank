# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE SAVE-STATE FILE: the state image (runtime/rg_state.h) behind two lines that say what it
        # is. The first is the format's version, so a later release can tell an old file and convert
        # it; the second names the game and build that wrote it, as the console and the digest of the
        # program (Network::Fingerprint), which is the same for the C, JavaScript and Ruby builds of
        # one game. A runtime refuses in plain words a file of another version or another build
        # before it reads a field.
        #
        #   vblank-state 1
        #   build gba 3f2a...
        #   game.x<TAB>1 12
        #   ...
        #
        # Each build is handed the version and its own build by the same names, as the console's
        # numbers are (ConsoleNumbers): a header beside the C, constants ahead of the JavaScript and
        # the Ruby.
        module StateFile
          VERSION = 1

          module_function

          # What a build of +program+ is told, by the name each runtime reads it as.
          def values(program)
            fingerprint = Network::Fingerprint.of(program, title: "")
            { "RG_STATE_VERSION" => VERSION, "RG_GAME_CONSOLE" => fingerprint.console, "RG_GAME_BUILD" => fingerprint.digest }
          end

          # The same as C defines, JavaScript constants and Ruby constants: a String quoted, a number
          # as it is.
          def c_text(program) = values(program).map { |name, value| "#define #{name} #{value.inspect}\n" }.join
          def js_text(program) = values(program).map { |name, value| "const #{name} = #{value.inspect};\n" }.join
          def ruby_text(program) = values(program).map { |name, value| "#{name} = #{value.inspect}\n" }.join
        end
      end
    end
  end
end
