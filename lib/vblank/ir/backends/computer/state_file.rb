# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # The save-state file: the state image (runtime/rg_state.h) behind two lines that say what it
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
        # the Ruby. With them goes how many rows the runtime's sprite tables have
        # (Picture.sprite_rows), which the game decides: the image's "sprites.drawn_places" holds a
        # place for each row, so it is laid out by the same build that names it, and a file from
        # another build is refused before it is read.
        module StateFile
          VERSION = 1
          # A game given a screen of its own size keeps the size of screen it shows as well
          # ("screen.shown_size"), so its states are of a version of their own and every other game's
          # read as before.
          SCREEN_OF_ITS_OWN_VERSION = 2

          module_function

          # The version of +program+'s states.
          def version_of(program) = program.described_console.screen_of_its_own ? SCREEN_OF_ITS_OWN_VERSION : VERSION

          # What a build of +program+ is told, by the name each runtime reads it as.
          def values(program)
            fingerprint = Network::Fingerprint.of(program, title: "")
            { "RG_STATE_VERSION" => version_of(program), "RG_GAME_CONSOLE" => fingerprint.console, "RG_GAME_BUILD" => fingerprint.digest,
              "RG_MAX_SPRITES" => Picture.sprite_rows(program) }
          end

          # The same as C defines, JavaScript constants and Ruby constants: a String quoted, a number
          # as it is.
          def c_text(program) = values(program).map { |name, value| "#define #{name} #{value.inspect}\n" }.join
          def js_text(program) = values(program).map { |name, value| "const #{name} = #{value.inspect};\n" }.join
          # Strings frozen, so the constants can be shared with a game played in a Ractor.
          def ruby_text(program)
            values(program).map { |name, value| "#{name} = #{value.inspect}#{".freeze" if value.is_a?(String)}\n" }.join
          end
        end
      end
    end
  end
end
