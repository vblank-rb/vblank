# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A ROUTINE TOO BIG FOR A BANK, CUT INTO PARTS THAT EACH FIT ONE. A cartridge bigger than the
      # processor can see at once is seen a bank at a time, and a routine has to be in one bank
      # whole: the processor cannot run on from the end of a bank into the next. So a routine whose
      # code comes to more than a bank holds is cut. A run of statements side by side becomes a
      # routine of its own, called where they stood; a statement too big to move whole — an `if`, a
      # `loop`, a `repeat` — has what is inside it cut the same way instead. The parts share the
      # routine's own numbers, which are kept in work memory, so nothing is handed between them.
      #
      # How big a bank is, and so how big a routine may come to, is the console's; the lowering says
      # it. Where to cut is the same on every console, and decided here.
      #
      # EACH ROUTINE IS MADE ONCE. Nearly every routine fits a bank, so it is made for real straight
      # away and its size read off the finished section. Only one that comes out too big is taken
      # back — the lowering put back as it was before it (its LOWERING_STATE's snapshot) — measured
      # whole by making it and throwing it away (its #bytes_of), cut, and made again as the routine
      # and its parts. Cutting wants each statement's size, at each depth it cuts inside: a lowering
      # that can tell what a statement would come to on its own while it measures the whole notes it
      # (#note_size), and cutting then measures nothing again; any statement not noted is measured
      # on its own.
      #
      # A routine an earlier try of the build found too big (BuildCache#routines_found_too_big) is
      # measured first instead, which is what it would come to after making it for nothing. That is
      # only a guess at the cost: whether to cut is still decided by what it measures now, by the
      # one rule (#fits?), so a routine that fits this try is made whole as any other.
      class RoutineCuts
        # A call of a part cut off a routine, standing where its statements stood.
        PartCall = Data.define(:label)

        # The cuts of +lowering+, a try of the build +cache+ is for. The lowering's class says how
        # big a routine and a part may come to (MOST_ROUTINE_BYTES, MOST_PART_BYTES), how many bytes
        # the instruction that ends a routine section takes (RETURN_BYTES: a section holds it and a
        # measurement does not) and what it holds while it makes one (LOWERING_STATE); its
        # #bytes_of measures a list of statements, keeping nothing.
        def self.for(lowering, cache)
          kind = lowering.class
          new(plan: cache.plan, most_routine_bytes: kind::MOST_ROUTINE_BYTES, most_part_bytes: kind::MOST_PART_BYTES,
              return_bytes: kind::RETURN_BYTES, measure: lowering.method(:bytes_of),
              snapshot: -> { kind::LOWERING_STATE.snapshot(lowering) }, found_too_big: cache.routines_found_too_big)
        end

        # +measure+ gives the bytes a list of statements comes to; +snapshot+ gives the lowering's
        # state now, which #restore! puts back (LoweringState#snapshot); +found_too_big+ is the Set
        # #sections adds the routines it cuts to, for later tries.
        def initialize(plan:, most_routine_bytes:, most_part_bytes:, return_bytes:, measure:, snapshot:,
                       found_too_big: Set.new)
          @plan = plan
          @most_routine_bytes = most_routine_bytes
          @most_part_bytes = most_part_bytes
          @return_bytes = return_bytes
          @measure = measure
          @snapshot = snapshot
          @found_too_big = found_too_big
          @cut = {} # a statement whose statements were cut into parts -> what stands for them
          @sizes = {}.compare_by_identity # a statement of the routine being cut -> its bytes on its own
        end

        # The sections of the routine named +label+, holding +statements+: the routine, and after it
        # each part cut off it to fit a bank. The block makes one section of a label and its
        # statements. A routine that fits is one section, made once.
        def sections(label, statements, &section)
          known = statements.map(&:object_id)
          unless @found_too_big.include?(known)
            before = @snapshot.call
            whole = yield(label, statements)
            return [whole] if fits?(whole.size - @return_bytes)

            before.restore!
            @found_too_big << known
          end
          kept, parts = fit(label, statements)
          [yield(label, kept), *part_sections(parts, &section)]
        end

        # +statements+ as a routine named +label+ holds them, and the parts cut off it to fit a bank,
        # measured before any of it is made: [the routine's statements, [[a part's label, its
        # statements], ...]]. A routine that fits is its statements as they are, with no parts. This
        # is for a routine the lowering wraps in code of its own (a timer's handler, run once a
        # tick), whose size is not one section's; any other is made by #sections.
        def fit(label, statements)
          @sizes.clear
          parts = []
          kept = fits?(@measure.call(statements)) ? statements : cut_list(statements, label, parts)
          [kept, parts]
        end

        # The section the block makes of each of +parts+ (#fit), after the routine they were cut off.
        def part_sections(parts) = parts.map { |part, held| yield(part, held) }

        # The bytes +node+ comes to on its own, noted by the lowering as it measures the routine
        # being cut, so cutting need not measure it again.
        def note_size(node, bytes)
          @sizes[node] = bytes
        end

        # The statements an `if`, a `loop` or a `repeat` holds, and an `if`'s `else`: its own, or
        # those they were cut into. A game loop's are what it runs each time round, in the console's
        # order (LoweringPlan#console_loop).
        def children_of(node)
          @cut.fetch(node.object_id) do
            body = node.kind == :loop ? @plan.console_loop(node).each_time : node.children
            [body, node.kind == :if ? node.else&.children || [] : []]
          end
        end

        private

        # The one rule for whether a routine of +bytes+ fits a bank whole, however its size was found.
        def fits?(bytes) = bytes <= @most_routine_bytes

        def cut_list(list, base, parts)
          kept = []
          run = []
          run_bytes = 0
          flush = lambda do
            next if run.empty?

            part = "#{base}_part#{parts.length + 1}"
            parts << [part, run]
            kept << PartCall.new(part)
            run = []
            run_bytes = 0
          end
          list.each do |node|
            size = @sizes.fetch(node) { @measure.call([node]) }
            if size <= @most_part_bytes
              flush.call if run_bytes + size > @most_part_bytes
              run << node
              run_bytes += size
            else
              flush.call
              kept << cut_inside(node, base, parts)
            end
          end
          flush.call
          kept
        end

        # A statement too big to move whole, with the statements it holds cut. Only an `if`, a
        # `loop` and a `repeat` hold statements that are made where they stand.
        def cut_inside(node, base, parts)
          return node unless %i[if loop repeat].include?(node.kind)

          body, otherwise = children_of(node)
          cut = [cut_list(body, base, parts), cut_list(otherwise, base, parts)]
          @cut[node.object_id] = cut
          node
        end
      end
    end
  end
end
