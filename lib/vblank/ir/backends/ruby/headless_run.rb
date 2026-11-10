# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # A game run as Ruby with no window (runtime/rg_headless.rb, played by the Ruby running
        # this), driven and read back through the calls a test makes on Backends::Reference.
        #
        # The windowless Ruby program prints the lines the native lowering's windowless program
        # prints, so everything about reading it — the variables, the lists, the picture file,
        # the sprites — is Computer::HeadlessRun's, and only the program it plays is this one's.
        class HeadlessRun < Computer::HeadlessRun
          # Raised for something a test asks that the Ruby lowering cannot answer yet. The shared
          # one's, since both are asked the same questions.
          CannotAnswer = Computer::HeadlessRun::CannotAnswer

          private

          def headless_program(program) = Ruby.new.build_headless(program)

          # The script is played by the Ruby running this, without RubyGems, which nothing in it
          # needs, and without the bundler settings a test run under `bundle exec` would hand on.
          #
          # It runs with YJIT when this Ruby does, and without when this one does not. YJIT is
          # what makes a game played as Ruby several times faster, and `vblank run` turns it on in
          # its own Ruby (or not, with --no-yjit): the Ruby that actually plays the game is this
          # one's child, which inherits none of that, so it is told on its command line.
          def program_command(script) = [PROGRAM_ENVIRONMENT, RbConfig.ruby, "--disable-gems", *jit_flags, script]

          def jit_flags = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? ["--yjit"] : []

          def lowering_name = "the Ruby lowering"
          def skip_helper_name = "skip_on_ruby"
        end
      end
    end
  end
end
