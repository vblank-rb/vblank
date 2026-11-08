# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Lowers a node by its kind: two kind-keyed tables (values, statements) of the PART that
        # writes each kind — Expressions, Drawing, Audio and the rest. Each part names the kinds it
        # owns (its STATEMENT_KINDS and VALUE_KINDS) and answers #emit_statement or #emit_value
        # with a `case` over them, so a kind's writer is a call written out, found by its name. The
        # table is filled once, in GBA#initialize, where every part and its kinds sit in one place.
        # A collaborator that needs to evaluate a value node (Collision's per-pixel test needs its
        # sprites' x/y/pose operands, which are themselves value nodes) depends on a Lowering
        # instead of on whichever file happens to own that node kind, so two collaborators can each
        # need the other's node kind without depending on each other directly.
        #
        # Two tables, not one — a value node and a statement node are different contracts (a value
        # leaves its answer in the accumulator; a statement leaves nothing live) — but they share
        # this wiring.
        class Lowering
          # +progress+ is what the build says it is doing; +emitter+ says how many bytes have been
          # emitted so far, which is what this pass shows as it goes. There is no count to work
          # towards — nothing knows how many instructions a program comes to until they are
          # emitted — so the growing size is the honest thing to show.
          #
          # +attribution+ counts what each node turned into. Every node in the program passes
          # through the two methods below, and this is the only place that is true, so this is
          # where the counting has to happen. See {Attribution}.
          def initialize(attribution:, emitter:, progress: Messages::Progress.silent)
            @values = {}
            @statements = {}
            @progress = progress
            @emitter = emitter
            @attribution = attribution
            @mode = :direct  # the mode draws currently lower in (set per func)
            @draw_area = nil # x, y, w, h while inside a clipped area; nil otherwise
          end

          # +owner+ writes every statement of +kinds+ (#emit_statement), or every value of them
          # (#emit_value). Safe to call more than once, since a part that is itself a collaborator
          # (Collision) is built after others; a kind two parts claim is refused.
          def statements_written_by(owner, kinds) = claim!(@statements, owner, kinds)
          def values_written_by(owner, kinds) = claim!(@values, owner, kinds)

          # THE KINDS THAT EMIT NOTHING WHERE THEY ARE WRITTEN: collected during the definitions
          # pass, or armed from it. A real owner, not a hole a missing kind would also leave, so
          # the coverage lock can't mistake one for the other.
          module NothingEmitted
            def self.emit_statement(_node) = nil
          end

          def value(node)
            @attribution.measure_node(node) { @values.fetch(node.kind) { unknown_value(node) }.emit_value(node) }
          end

          # For a node the caller lowers its own way rather than through #value: a test branched
          # on, an operand loaded straight into a register. It is charged as #value charges one.
          def measure_value(node, &) = @attribution.measure_node(node, &)

          # Every statement in the program is lowered through here, nested ones included, so
          # this is where the pass says it is still going. One report per STATEMENT, not per
          # instruction: an instruction is what a statement turns into, and a build that
          # reported on each would spend more time saying so than emitting.
          def statement(node)
            @progress.tick { "#{@emitter.pos} bytes" }
            @attribution.measure_statement(node) do
              @statements.fetch(node.kind) { unknown_statement(node) }.emit_statement(node)
            end
          end

          # Every kind with a value/statement writer — read by the coverage test that
          # checks these tables against IR::Nodes.by_kind.
          def value_kinds = @values.keys
          def statement_kinds = @statements.keys

          # Which mode the draws inside +block+ lower in — :direct, :buffered, or :tiled.
          # Restored on the way out, so a nested call (a func called from within another
          # func's body) can't leak its mode past its own return.
          attr_reader :mode

          def in_mode(mode)
            was = @mode
            @mode = mode
            yield
          ensure
            @mode = was
          end

          # The screen area every shape below +block+ clips against — [x, y, w, h], or
          # nil for the whole screen. `inside` doesn't nest at the surface (a guardrail
          # error there), so this doesn't need to model a stack either.
          attr_reader :draw_area

          def with_draw_area(x, y, w, h)
            @draw_area = [x, y, w, h]
            yield
          ensure
            @draw_area = nil
          end

          private

          def claim!(table, owner, kinds)
            taken = kinds.select { |kind| table.key?(kind) }
            raise ArgumentError, "the kinds #{taken.inspect} already have a writer" if taken.any?

            kinds.each { |kind| table[kind] = owner }
          end

          def unknown_value(node)
            raise LoweringError, "the GBA backend cannot evaluate #{node.kind.inspect}"
          end

          def unknown_statement(node)
            raise LoweringError, "the GBA backend cannot lower #{node.kind.inspect} yet"
          end
        end
      end
    end
  end
end
