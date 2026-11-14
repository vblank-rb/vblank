# frozen_string_literal: true

require "set"

module VBlank
  module IR
    module Guardrails
      module Checks
        # A `while` in normal Ruby on a test the game makes, with no wait for the next frame
        # anywhere in it, and nothing in it that can change what its test reads. The screen is
        # drawn and the buttons are read between frames, so a loop like that holds the whole game
        # still, and since only a frame could make its test fail, the game has stopped for good.
        #
        # A loop of a known length is an ordinary way to do work inside a frame, so `repeat` is
        # left alone: only the count such a `while` is given is looked for. A `while` whose own
        # work changes what its test reads is the same kind of work, counted by the game rather
        # than by a number: `while i < n` with `i += 1`, or a retry that clears its flag once a
        # try succeeds (a stage laid out at random squares until each one fits). Whether such a
        # loop ends cannot be proved from the tree, but it CAN end without a frame, which a loop
        # on a button never can, so it is left alone too. The loop's work is everything in
        # it and every routine it calls, on either side of every `if`, since any of them can
        # be the round that ends it.
        #
        # A variable counts as changed by any statement that names it. That errs toward silence:
        # a statement that only reads a name in a field of its own (not in a value it works
        # out) hides a loop that never ends, but never makes one that does end warn.
        class LoopNeverWaits
          NAME = :loop_never_waits
          PLAIN_NAME = "a loop with no wait for the next frame"

          # The biggest number the game's arithmetic holds. A `while` has no count of its own,
          # and a loop in the game must be given one.
          MOST_PASSES = 0x7FFF_FFFF

          def detect(program)
            funcs = FrameReach.index_funcs(program)
            stuck = program.each.select do |node|
              open_ended_loop?(node) && !waits?(node, funcs) && !changes_own_test?(node, funcs)
            end
            stuck.map { |node| Finding.new(check: NAME, severity: :warning, message: message, node: node) }
          end

          private

          def open_ended_loop?(node)
            node.kind == :repeat && node.count.kind == :int && node.count.value == MOST_PASSES
          end

          def waits?(node, funcs)
            FrameReach.per_frame_statements(node, funcs).any? { |statement| statement.kind == :wait_vblank }
          end

          # Whether anything the loop does can change a name its test reads.
          def changes_own_test?(node, funcs)
            test, work, test_calls = test_and_work(node)
            read = test.flat_map { |part| names_read(part) }.to_set
            written = names_written(work, funcs)
            routines_written(test_calls, funcs, Set.new, written)
            read.intersect?(written)
          end

          # [the parts of +node+ its test is worked out from, the statements of its work, the
          # routines working the test out calls].
          #
          # A test that records statements of its own (Builder#open_repeat_rerunning_test_statements)
          # is asked inside the loop: those statements first, then an `if` that sets the loop's
          # stop flag, its `else` the body. The flag is written on every round, so the test is
          # what the `if` and those statements read, and the work is the body and any routine
          # those statements call. Any other loop's test is its +stop_when+, and its work is
          # everything in it.
          def test_and_work(node)
            *asking, ask = node.children
            stop = node.stop_when
            return [[stop], node.children, []] unless stop.kind == :var_ref && sets_stop_flag?(ask, stop.name)

            [[*asking, ask.cond], ask.else.children, asking.flat_map { |statement| statement.each.flat_map(&:callees) }]
          end

          def sets_stop_flag?(ask, flag)
            return false unless ask&.kind == :if && ask.else && ask.children.size == 1

            set = ask.children.first
            set.kind == :set && set.var == flag
          end

          # The names the values under +part+ read: a variable, a list, a button.
          def names_read(part)
            part.walk.select(&:value?).flat_map { |value| names_in(value) }
          end

          # The names the statements of +work+ name, and those of every routine they call.
          def names_written(work, funcs, seen = Set.new, names = Set.new)
            work.each do |statement|
              statement.each do |inner|
                names.merge(names_in(inner)) if inner.statement?
                routines_written(inner.callees, funcs, seen, names)
              end
            end
            names
          end

          # The names the routines +targets+ write, added to +names+, each routine once.
          def routines_written(targets, funcs, seen, names)
            targets.each do |target|
              next if seen.include?(target) || !funcs.key?(target)

              seen << target
              names_written(funcs[target].children, funcs, seen, names)
            end
          end

          def names_in(node) = node.named_operands.flat_map { |_, value| Array(value).flatten.grep(Symbol) }

          def message
            "This loop never waits for the next frame. The game does not draw and does not read " \
              "the buttons until the loop ends. To fix this, add `wait_vblank` inside the loop."
          end
        end
      end
    end
  end
end
