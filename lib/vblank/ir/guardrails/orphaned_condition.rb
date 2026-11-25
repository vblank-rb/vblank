# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a test such as `x > 5` that the game makes and never uses:
        #
        # > You made a test like `x > 5`, but the game does not use it. This line is in code that
        # > VBlank does not read as a game, so Ruby takes the test as always true. To fix this, move
        # > the line into your `VBlank.game` block. If the line is in a file of its own, load that
        # > file with `VBlank.require_game_file`, not `require_relative`.
        #
        # A test on the game's numbers is not true or false while the game is built: it is a
        # question the game asks each time it runs. Inside the `VBlank.game` block, a plain Ruby
        # `if x > 5` is turned into that question. Outside it, Ruby sees only an object, takes it
        # as true, and the branch always runs with the test ignored. Move the line into the game's
        # block, or load the file it is in with `VBlank.require_game_file`.
        #
        #--
        # The native-`if` slip. A comparison in this DSL is a Condition object, and
        # Ruby treats any object as true, so `if x > 5` runs its body every time
        # with the comparison silently ignored — no error, just a ROM that always
        # takes the branch. A black-screen-class footgun, and Ruby gives no hook to
        # intercept a plain `if` on a truthy object.
        #
        # So unlike the other checks, this one can't detect by walking the IR: an
        # unused Condition never records a node, so there's nothing in the tree to
        # see. Detection lives in the builder instead — a Condition joins a "pending"
        # set when built and leaves it when used, so the leftovers *are* the orphans
        # (see Builder#track_condition). This check is handed that leftover set and
        # turns each into a Finding; it ignores the program because its data is the
        # pending set, not the tree. That lets it run as an ordinary check in the
        # Validator's list, no special path.
        #
        # It reports errors, not warnings: a Condition built and never branched on
        # did nothing at all, and the only way that happens is the native-`if` slip
        # — there's no legitimate cause to weigh against.
        #++
        class OrphanedCondition
          NAME = :orphaned_condition
          PLAIN_NAME = "a test nothing branched on"

          # @param pending [Array<Condition>] the Conditions built but never used
          def initialize(pending)
            @pending = pending
          end

          # One Finding per leftover Condition. The program is irrelevant here — the
          # data is the pending set — so it's ignored. The class is named rather than asked of
          # self, for the reason Validator#plain_name gives.
          def detect(_program)
            @pending.map { |condition| OrphanedCondition.finding(condition) }
          end

          # A Finding for a Condition built but never used to branch. The Condition
          # itself is what the finding blames: it carries the author's call site, and
          # there is no node to point at (an orphan records none — that's the whole
          # reason this check reads a pending set instead of the tree). Standalone so
          # the message is easy to assert.
          def self.finding(condition)
            message =
              "You made a test like `x > 5`, but the game does not use it. This line is in code " \
              "that VBlank does not read as a game, so Ruby takes the test as always true. To " \
              "fix this, move the line into your `VBlank.game` block. If the line is in a file " \
              "of its own, load that file with `VBlank.require_game_file`, not `require_relative`."
            Finding.new(check: NAME, severity: :error, message: message, node: condition)
          end
        end
      end
    end
  end
end
