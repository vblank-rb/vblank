# frozen_string_literal: true

module VBlank
  module IR
    # What a build asks of a program before it makes anything from it, written once. Two kinds of
    # caller run these: VBlank.build, before it makes a cartridge, and a game's test players
    # (Testing::BuildChecks), before they play a test's program. When each wrote its own list, a
    # check one of them gained was missing from the other: a test played and passed a game the
    # build refuses, or failed far down a lowering where the build names the line.
    #
    # The order is the build's. First the tree is proved well-formed (Verifier). That checks the
    # library's own consistency, not the developer's game, so a malformed tree is a VBlank bug and
    # raises at once, before it can reach the guardrails and a backend and fail cryptically two
    # passes downstream. One mismatch is the author's: a number the game works out, handed to a
    # verb that takes only a written one. That one raises Guardrails::ValidationError naming the
    # verb and the line. Then the guardrails walk the tree and report what they find. Nothing is
    # fixed for the author.
    module ProgramChecks
      module_function

      # Raises on the first fault in +program+'s tree. A debug_halt build stops here, its tree cut
      # short on purpose, and so does the interpreter's own run, which plays a game whatever its
      # console's build would say of it (Testing::BuildChecks).
      def refuse_malformed!(program, progress: Messages::Progress.silent)
        progress.step("Checking program")
        Verifier.verify!(program)
      end

      # The proof above, then the guardrails' Report of what +checks+ found in +program+.
      def findings_for!(program, checks: Guardrails.default_checks, progress: Messages::Progress.silent)
        refuse_malformed!(program, progress: progress)
        progress.step("Checking for mistakes")
        Guardrails::Validator.new(checks: checks, progress: progress).run(program, autofix: false)
      end
    end
  end
end
