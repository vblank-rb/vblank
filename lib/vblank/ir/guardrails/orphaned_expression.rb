# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a number the game works out and then does nothing with, such as
        # `flags | 4` or `hp + 1` on a line of its own:
        #
        # > You worked out a number and then did nothing with it. So the program is unchanged and
        # > the work is thrown away. `flags | 4` gives you a NEW number and leaves `flags` as it
        # > was. To change the variable, write `flags |= 4`, and `hp += 1` for `hp + 1`. If you
        # > wrote that already, this line is in code that VBlank does not read as a game. To fix
        # > this, move the line into your `VBlank.game` block. If the line is in a file of its
        # > own, load that file with `VBlank.require_game_file`, not `require_relative`.
        #
        # A word that used to change a variable and now works out a new one (`d.abs` where
        # `d.abs!` was meant) gets a message of its own:
        #
        # > `<word>` works out a new number and leaves the variable as it is. Nothing uses that
        # > number here, so this line does nothing. A word that changes a variable ends in `!`. To
        # > change the variable, write `<word>!`.
        #
        # The line does nothing at all, so the game quietly does not do what it reads as doing.
        # Write the form that changes the variable (`+=`, `|=`, or the word ending in `!`). Inside
        # the `VBlank.game` block `flags |= 4` changes the game's variable; outside it, Ruby moves
        # the name and the variable stays as it was, so move the line into the block.
        #
        #--
        # The `|=` slip, and everything shaped like it. Setting a flag in C is written
        # `flags |= MASK`, and both ways a person carries that over are silent:
        #
        #   flags | MASK      # an expression nobody kept — the flag is never changed
        #   flags |= MASK     # Ruby reads this as `flags = flags | MASK`, which rebinds
        #                     # the Ruby local to an expression. The game's variable is
        #                     # untouched, and the name still looks right afterwards.
        #
        # The same hole swallows `hp + 1` where `hp += 1` was meant. Nothing is emitted,
        # nothing complains, and the game quietly does not do the thing.
        #
        # How it is found, which is the interesting part. This check cannot walk the tree,
        # for the same reason the orphaned-Condition check cannot: an expression nobody
        # kept is by definition not in the tree, so there is nothing there to see. But it
        # needs no "consume" bookkeeping either, because the tree already records what was
        # used — a node written into another node has its parent wired back (see IR::Node),
        # so an expression that found a home has a parent and one that did not has none.
        # The builder hands over every expression it built; the unparented ones are the
        # orphans.
        #
        # That test only works because the framework does not build expressions of its
        # own. It used to: a list checking a value against what it holds constructed a
        # throwaway Value purely to borrow the scale-alignment rules, so `xs.push cx` left
        # an unparented expression behind and looked exactly like this mistake. The rules
        # live in {Scale} now, which a list and a pool field ask directly.
        #
        # The other way it broke was a number built to hand to a block: the instance a pool's
        # routine runs on, the row a bend is working out, the thing a drawing order is asked
        # about. A block that had no use for it left it unparented, and its author was told
        # they had thrown a number away. Those are built by Value.handed_to_block now, which
        # this never hears about.
        #
        # It reports errors, not warnings. An expression built and dropped did nothing at
        # all, and there is no legitimate reason to write one — unlike a statement, it has
        # no effect to be had.
        #++
        class OrphanedExpression
          NAME = :orphaned_expression
          PLAIN_NAME = "a number worked out and thrown away"

          # @param expressions [Array<Value>] every expression Value the build made
          def initialize(expressions)
            @expressions = expressions
          end

          # One Finding per expression whose node never joined the tree. The program is
          # not consulted: an orphan is precisely what is missing from it. The class is named
          # rather than asked of self, for the reason Validator#plain_name gives.
          def detect(_program)
            @expressions.reject { |value| value.node.parent }.map { |value| OrphanedExpression.finding(value) }
          end

          # The Value itself is what the finding blames — it carries the author's call
          # site, and there is no node in the tree to point at. Standalone so the message
          # is easy to assert.
          def self.finding(value)
            return Finding.new(check: NAME, severity: :error, message: changing_message(value), node: value) if value.bang_spelling

            message =
              "You worked out a number and then did nothing with it. So the program is " \
              "unchanged and the work is thrown away. `flags | 4` gives you a NEW number and " \
              "leaves `flags` as it was. To change the variable, write `flags |= 4`, and " \
              "`hp += 1` for `hp + 1`. If you wrote that already, this line is in code that " \
              "VBlank does not read as a game. To fix this, move the line into your " \
              "`VBlank.game` block. If the line is in a file of its own, load that file with " \
              "`VBlank.require_game_file`, not `require_relative`."
            Finding.new(check: NAME, severity: :error, message: message, node: value)
          end

          # One of the words that used to change a variable, written the old way. `d.abs` on a
          # line of its own changed d once; now it works out a new number and changes nothing,
          # so the likeliest meaning is the `!` form, and the message says it by name.
          def self.changing_message(value)
            bare = value.bang_spelling.delete("!")
            "`#{bare}` works out a new number and leaves the variable as it is. Nothing uses " \
              "that number here, so this line does nothing. A word that changes a variable ends " \
              "in `!`. To change the variable, write `#{value.bang_spelling}`."
          end
        end
      end
    end
  end
end
