# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE VARIABLES THAT ONLY EVER HOLD 16 BITS, though the game never declared them narrow, so
        # the Super Nintendo's lowering keeps each in two bytes (Lowering#half_variable?). The 65816
        # works 16 bits at a time with its accumulator wide (fullsnes, "CPU 65XX Microprocessor"), so
        # a four-byte variable is two loads and two stores for every read and write, and a sum is two
        # adds with the carry between them. The console's own games keep a place on the screen or a
        # step in one word. Keeping one in two bytes changes nothing the game computes: every write
        # to it is proven to give a number from -32768 to 32767 (Backends::NumberRanges says how),
        # which two bytes hold exactly, and a read that needs the whole number copies its sign
        # upward (Lowering#load_variable).
        #
        # Kept whole besides what the proof cannot bound: the frame's own counters and the music's
        # volume, which the runtime reads in four bytes (Lowering::NEAR_ONLY); a repeat's count and a
        # pool's own variables, which the lowering steps its own way; and the ones the lowering
        # names (+also_whole+), a game loop's own numbers and any a try found it needed whole.
        module HalfVariables
          module_function

          # The variables of +program+ kept in two bytes, given its +plan+ (LoweringPlan).
          def proven(program, plan, also_whole: [])
            loops = plan.game_loops.flat_map { |node| plan.console_loop(node).variables }
            whole = loops + also_whole + Lowering::NEAR_ONLY + stepped_by_lowering(program)
            NumberRanges.new(program, also_whole: whole).variables_within(NumberRanges::HALF).to_set
          end

          # The variables the lowering writes or reads in its own way, outside the statements that
          # name them: each repeat's count, and every variable of a pool's own, which a pool's layout
          # keeps scaled or reads whole where its walk steps (Backends::PoolLayout).
          def stepped_by_lowering(program)
            repeats = program.walk.select { |node| node.kind == :repeat }
            pooled = Reach.variables(program).select { |name| Messages::MadeNames.read(name)&.first == :pool_part }
            (repeats.filter_map(&:index) + pooled).uniq
          end
        end
      end
    end
  end
end
