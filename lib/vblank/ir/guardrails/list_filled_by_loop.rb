# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A warning about a list that setup fills with one value, an item at a time, such as
        # `repeat(64) { enemies.push 0 }`:
        #
        # > The list :<name> is filled one item at a time in a loop in setup<at file:line>.
        # > Each push finds the place for its item and stores the length again, so the loop
        # > costs much more than one fill, and the game shows its first picture later. To fill
        # > the list in one step, declare it with <`full_of: 0`>, and remove the loop.
        #
        # Where the value pushed is not 0, the fix reads "declare it with `full_of:` and the
        # value the loop pushes". The place in the game's file is left out where it is not
        # known.
        #
        # The game works, but starts more slowly than it needs to. Declare the list with
        # `full_of:` and remove the loop. A loop that fills only part of a list, or pushes a
        # different value each time, is not warned about.
        #
        #--
        # A list filled to its capacity with one value, a PUSH at a time: `repeat(64) {
        # name.push 0 }`, usually in setup so every item is there to index from the start.
        # It works, and `full_of: 0` where the list is declared does the same in one step. A
        # push works out where the item goes and stores the length again, so on the console a
        # loop of them costs many times what one fill does, and in setup all of it lands on
        # the first pass, before the game has shown anything.
        #
        # Only a loop at power-on that certainly fills the list is named: one in the game's
        # setup, with a count that is the list's capacity and a body that is that one push of a
        # number written in the game. A loop that fills part of a list, or pushes a different
        # value each time, is something `full_of:` cannot express; and one that runs later, filling
        # a list the game emptied, is not what a declaration does.
        #
        # The value is named in the advice only when it is nought. A list of fractions keeps
        # its items multiplied up, so the number in the push is not always the number the game
        # wrote, and nought is the one number that reads the same either way.
        #++
        class ListFilledByLoop
          NAME = :list_filled_by_loop
          PLAIN_NAME = "a list filled one item at a time"

          # +arrays+ are the lists a plain Ruby Array made, by name, with the local the game wrote
          # (Guardrails::BuildFacts), so the advice is the Array's start and not `full_of:`.
          def initialize(arrays: {})
            @arrays = arrays
          end

          # The same check, knowing which lists are Arrays the game wrote.
          def told_of(facts) = ListFilledByLoop.new(arrays: facts.collections_from_arrays)

          def detect(program)
            capacities = program.walk.select { |node| node.kind == :list_new }.to_h { |node| [node.name, node.capacity] }
            program.children.filter_map do |node|
              push = filling_push(node, capacities)
              next unless push

              Finding.new(check: NAME, severity: :warning, message: message_for(push, node), node: node)
            end.uniq { |finding| finding.node.children.first.name }
          end

          private

          # The one push of a written number that +node+ repeats as many times as the list
          # holds, or nil when +node+ is anything else.
          def filling_push(node, capacities)
            return unless node.kind == :repeat && node.count.kind == :int && node.children.length == 1

            push = node.children.first
            return unless push.kind == :list_push && push.value.kind == :int

            push if capacities[push.name] == node.count.value
          end

          def message_for(push, loop_node)
            where = loop_node.source ? " at #{loop_node.source}" : ""
            local = @arrays[push.name]
            return array_message(local, push, loop_node.count.value, where) if local

            value = push.value.value.zero? ? "`full_of: 0`" : "`full_of:` and the value the loop pushes"
            "The list :#{push.name} is filled one item at a time in a loop in setup#{where}. Each push " \
              "finds the place for its item and stores the length again, so the loop costs much more than " \
              "one fill, and the game shows its first picture later. To fill the list in one step, declare " \
              "it with #{value}, and remove the loop."
          end

          def array_message(local, push, size, where)
            start = if push.value.value.zero? then "`Array.new(#{size}, 0)`"
                    else "`Array.new(#{size}, n)`, where n is the number the loop adds"
                    end
            "The Array `#{local}` is filled one item at a time in a loop in setup#{where}. Each item added finds " \
              "its place and stores the size again, so the loop costs much more than one fill, and the game shows " \
              "its first picture later. To fill the Array in one step, make it full where it is made: " \
              "#{start}, with the other settings it has now. Then remove the loop."
          end
        end
      end
    end
  end
end
