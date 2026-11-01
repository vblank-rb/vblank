# frozen_string_literal: true

# HOW A TEST RUN'S WARNINGS STAY WORTH READING. A test's game says `reads = 0` and the game rewrite
# makes a variable of it (DSL::PlainRuby), which the test reads back by name, so Ruby sees a local
# nothing uses and warns, some hundreds of times a run. Renaming one `_reads` would rename the game's
# variable, so that one warning is left out, for test files alone. Loaded ahead of the test files
# (TestTask, ruby -r), since Ruby warns as it reads a file.
module VBlank
  module Testing
    module QuietWarnings
      UNUSED_IN_A_TEST = %r{/test/.*: warning: assigned but unused variable - }

      module_function

      def noise?(message) = message.match?(UNUSED_IN_A_TEST)

      # In front of Ruby's own Warning.warn.
      module LeaveOutNoise
        def warn(message, **options)
          super unless QuietWarnings.noise?(message)
        end
      end
    end
  end
end

Warning.extend(VBlank::Testing::QuietWarnings::LeaveOutNoise)
