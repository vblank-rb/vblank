# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHY THE EMULATOR WOULD NOT LOAD, AND WHAT TO DO ABOUT IT: three failures that look the same
    # and need different advice, told apart by facts about the process. Emulator works the facts out
    # and raises with #advice; a test hands them in, so each message can be asked for on its own
    # without arranging a machine where the emulator is missing in that way.
    #
    # +detail+ is what the loader said, +bundled+ whether ruby-gba-emulator is in the bundle, and
    # +not_built+ the reason an install that could not build the emulator left beside it
    # (ext/vblank/emulator_builds.rb), or nil.
    #
    # What the loader said is the first thing to ask rather than the last. A binary built by another
    # Ruby announces itself: the loader names the library it will not link against. Read that first,
    # because the question underneath it — is the gem in the bundle — answers no for every tool run
    # as a plain `ruby` subprocess however the load failed, and then somebody is told to add a
    # Gemfile line they already have.
    #
    # Under that the two cases are: the gem is not in the bundle at all, which is the usual one and
    # the reader is building a game; or it IS there and its C extension was never compiled, which is
    # what a `path:` entry gets you, because bundler builds extensions for gem and git sources and not
    # for path ones. A resolvable spec means the gem is present and the build is what is missing.
    class MissingEmulator < Data.define(:detail, :bundled, :not_built)
      # How a loader says it found a library belonging to another Ruby. macOS names the libruby it
      # refuses; Linux names the one it cannot find.
      STALE_BUILD = /incompatible|libruby/i

      def initialize(detail:, bundled:, not_built: nil) = super

      # The words a person is told, starting with what to run.
      def advice
        return not_built_advice if not_built
        return stale_advice if detail.match?(STALE_BUILD)
        return unbuilt_advice if bundled

        missing_gem_advice
      end

      private

      def not_built_advice
        <<~NOT_BUILT
          An emulator is required to run a ROM. This copy of VBlank was installed without one:

              #{not_built.strip}

          To fix this, install what is missing, then run:

              gem pristine vblank
        NOT_BUILT
      end

      def stale_advice
        <<~STALE
          An emulator is required to run a ROM. The ruby-gba-emulator extension is built, but a
          different Ruby built it, and an extension loads only in the Ruby that made it.

              rake compile_emulator

          Each Ruby keeps a build of its own, so you do this one time for each Ruby.
        STALE
      end

      def unbuilt_advice
        <<~BUILD
          An emulator is required to run a ROM. ruby-gba-emulator is in your bundle, but its C
          extension is not built — bundler does not build one for a `path:` source.

              rake compile_emulator
        BUILD
      end

      def missing_gem_advice
        <<~ADD
          An emulator is required to run a ROM, and ruby-gba-emulator will not load.
          Put this in your Gemfile, then run bundle install:

              git "https://github.com/vblank-rb/vblank.git",
                  glob: "{,ruby-gba-emulator/}*.gemspec" do
                gem "vblank"
                gem "ruby-gba-emulator"
              end

          One block for both, because both gems live in that one repository. Two separate
          `gem ... github:` lines make bundler clone it twice into one directory, and the
          clone fails.

          It builds a C extension, so it needs a C compiler and libmgba
          (brew install mgba, or apt install libmgba-dev).
        ADD
      end
    end
  end
end
