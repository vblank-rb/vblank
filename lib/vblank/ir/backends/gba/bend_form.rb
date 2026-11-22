# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Which of the two ways a row-by-row bend is lowered, decided from the program alone.
        #
        # Where the offsets come from is the same either way. The block is run for all 160 rows
        # in the gap between frames, into a table. That is where everything else about a frame
        # is settled too — the sprites' positions, a background's scroll — so a bend shows the
        # frame that moved it at the same moment they do. Working the rows out while the
        # picture is being drawn instead would show a bend a frame ahead of the sprite standing
        # on it, and would race the display down the screen besides.
        #
        # What the two ways differ in is who moves a row's number out of that table and into
        # the scroll register, once per line, as the display asks for it.
        #
        # The copier is the cheap one, and the usual one. One of the console's copying engines
        # can be told "move one number into this register at the end of every line", and from
        # then on it feeds the register itself with the CPU untouched. The per-line cost goes
        # to nothing at all, so a bend costs only the table.
        #
        # One engine per bending layer, since an engine feeds one register. Three of the four
        # can be lent out, which is where the ceiling comes from.
        #
        # The interrupt is the fallback, for when there is no engine left. The display
        # announces the end of every line it draws, the console stops the game, and the
        # handler reads that line's number out of the table and writes it. It does the same
        # work the engine would, so the picture is the same — it just costs being stopped and
        # restarted 228 times a frame, most of which is the console's own doing on the way in
        # and out and nothing we write reaches.
        #
        # A program with no frame has nowhere to fill a table, and then the interrupt runs the
        # block itself, line by line. Nothing is paced in such a program, so there is nothing
        # for the bend to be in step with.
        #
        # This answer is asked for in two places, here where the bend is emitted and in the
        # cost estimate, which has to charge for the lowering that will really run. It lives in
        # one place so the two cannot drift apart — the same reason {LoopForm} does.
        module BendForm
          module_function

          # The engines a bend can ride, in the order they are handed out. There are four in
          # the console. The last is the general copier every fill and upload uses, so it can
          # never be given away; the other three can, but only while nothing else wants them.
          #
          # The three go in this order because the console serves the lower-numbered one first
          # when two want to move at the same moment, and a line-end move is the one thing
          # here that cannot wait.
          FREE_ENGINES = [0, 1, 2].freeze

          # ...and the pair sampled sound is entitled to. It feeds a stream of PCM to the
          # sound hardware continuously, which is exactly the standing claim on an engine a
          # bend makes, so the two cannot share. Measured on the emulator, they do not fail
          # halfway: hand a bend the engine the sound was using and the game goes silent,
          # with the picture none the wiser.
          #
          # Today the mixer sums everything into one voice and takes only the first of these.
          # The second is held back on purpose rather than lent out — a game that grew a
          # second voice would otherwise lose its sound to a bend, and nothing about adding a
          # bending layer suggests that is what happened.
          SOUND_ENGINES = [1, 2].freeze

          # How many bends this program can feed from an engine: all three when nothing else
          # is using them, one when it plays sampled sound.
          def free_engine_count(program)
            free_engines(program).length
          end

          def free_engines(program)
            return FREE_ENGINES if program.walk.none? { |node| node.kind == :play_sample }

            FREE_ENGINES - SOUND_ENGINES
          end

          # Everything fed to the display a row at a time: each bending layer, and the light
          # (a spotlight's window edges are a number a row exactly as a bend's scroll is, and
          # take an engine the same way). The light is one however often it is declared, and a
          # bend one for each background it bends (RowBends): one replaced by a later bend of the
          # same background, or written for a name the game never declares, takes no engine.
          def row_feeds(program)
            fed = RowBends.new(program).nodes
            light = program.walk.find { |node| node.kind == :shade_outside }
            light ? fed + [light] : fed
          end

          # Whether this program's rows are worked out into a table ahead of the frame. They
          # are, whenever there is a frame to work them out in — which is what a wait for one
          # is. A program with no frame has no such moment and runs its block per line instead.
          def rows_precomputed?(program)
            !row_feeds(program).empty? && program.walk.any? { |node| node.kind == :wait_vblank }
          end

          # ...and the other side of the same answer: rows worked out per line, because the
          # program they are in never waits for a frame.
          def rows_per_scanline?(program)
            !row_feeds(program).empty? && !rows_precomputed?(program)
          end

          # Whether this program's tables are fed to the display by a copying engine rather
          # than by a per-line interrupt. All of them or none: the interrupt costs what it
          # costs the moment one table needs it, and feeding one by engine beside it would
          # save nothing.
          def fed_by_dma?(program)
            fed = row_feeds(program)
            !fed.empty? && interrupt_reason_for(program, fed).nil?
          end

          # Why the interrupt was kept, in the words an author would use, or nil when the
          # copier took it. Read off the same test the answer comes from, so "it did not" and
          # "here is why" can never disagree.
          def kept_interrupt_reason(program)
            fed = row_feeds(program)
            fed.empty? ? nil : interrupt_reason_for(program, fed)
          end

          def interrupt_reason_for(program, fed)
            if !rows_precomputed?(program)
              "the program never waits for a frame, so there is no moment to work the rows out in"
            elsif fed.length > free_engine_count(program)
              too_many_bends_message(program, fed)
            end
          end

          # More things fed a row at a time than there are engines to feed them. Naming what
          # took the others is the whole use of this line: with sampled sound in the game there
          # is one engine, and moving a bend is not what an author would think to try.
          def too_many_bends_message(program, fed)
            free = free_engine_count(program)
            taken = free < FREE_ENGINES.length ? ", and this game's sampled sound holds the rest" : ""
            "there are #{fed_in_words(fed)} and #{free} copying #{free == 1 ? 'engine' : 'engines'} free#{taken}"
          end

          def fed_in_words(fed)
            bends = fed.count { |node| node.kind == :scroll_rows }
            said = "#{bends} bending #{bends == 1 ? 'layer' : 'layers'}"
            fed.length > bends ? "#{said} and a spotlight" : said
          end
        end
      end
    end
  end
end
