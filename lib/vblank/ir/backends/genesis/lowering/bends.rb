# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # A background bent row by row (`scroll_each_row`), lowered for a Genesis. Mixed into Lowering.
          #
          # The video chip reads each plane's sideways scroll from a table in video memory, and it can
          # read one for the whole screen or one for every line: register 11's two low bits, 11 for a
          # line each (plutiedev, "Scrolling"; the Sega Genesis VDP documentation, register $0B). Line by
          # line, the table holds a long word a line, plane A's scroll and then plane B's, for all the
          # lines of the screen. That is how the console's own games ripple water and split a road: the
          # table worked out in work RAM while the game runs, and sent into video memory in the blank by
          # the chip's own copy (DMA), which moves it without the processor.
          #
          # So a game that bends turns the chip to a line each as it starts, and:
          #
          # - at each wait, before the frame's sprites and scroll go out, every bend's rows are worked out
          #   in the order every lowering works them out in (BendSchedule), each row's offset kept in a
          #   table of the bend's own, a word a row;
          # - as the wait ends the pass (Runtime::Tiles' rt_picture_prepare), each plane's lines are
          #   worked out into the line table from its scroll and the bend shown on it, if any;
          # - and the blank sends the line table where the two words of a still screen went.
          #
          # A plane shows the bend of the background up on it (Reference#bend_offset_at): the bend
          # noted as the background goes up (#emit_bend_shown), nought for one that does not bend.
          module Bends
            # The bend whose rows a wait works out, in a game whose bends are one routine
            # (LoweringPlan#bends_in_own_routine?).
            BENDS = "bends frame"

            # Reference#exec_scroll_rows: a standing declaration, gathered up front (#bends). Its rows
            # are worked out at every wait (#emit_bends), not where it is written.
            def emit_scroll_rows(_node) = nil

            # The game's bends (RowBends): the last a background is given, in the order the backgrounds
            # were first bent.
            def bends = @plan.row_bends.bends

            def bend_screen_height = Console::GENESIS.screen_height

            # Reference#work_out_bends, before the pass's wait. +painting+ is the interpreter painting a
            # game that never waits, row by row (Reference#bend_offset_at), which leaves each row variable
            # at the last row painted rather than past it.
            def emit_bends(painting: false)
              @painting_bends = painting
              emit_bends_worked_out
            ensure
              @painting_bends = false
            end

            # At a wait: the bends' rows, in place or by the routine they are kept in.
            def emit_bends_at_wait
              return if bends.empty?

              @plan.bends_in_own_routine? ? call_routine(BENDS) : emit_bends
            end

            # That routine, with the numbers of a call its steps can come inside put back around them
            # (#with_call_numbers_kept), which are known only once every routine of the game is made.
            def bend_sections
              return [] unless @plan.bends_in_own_routine?

              [routine_section(BENDS, [], routine: "the bends") { with_call_numbers_kept { emit_bends } }]
            end

            # Rows +first+ to +past+ - 1 of +bend+: its row in its variable, its steps, the row's offset
            # kept, and on to the next, leaving the variable at +past+. A single row leaves it at that row.
            def emit_bend_rows(bend, first, past)
              top = fresh("bend_row")
              store_number(bend.row, first)
              place_label(top)
              bend.body.each { |child| statement(child) }
              emit_row_offset_kept(bend)
              return if past - first == 1

              emit_increment(bend.row)
              jump_if(Build.binop(:<, Build.var_ref(bend.row), Build.int(past)), top)
            end

            # The rows' loop stops with the variable at the height; a game that never waits leaves it at
            # the last row painted.
            def emit_row_variable_set(bend, height)
              statement(Build.set(bend.row, height - 1)) if @painting_bends
            end

            # The offset of the row in the bend's variable, its low word, kept at that row of the bend's
            # table. The chip takes the scroll's low ten bits, so the low word is all a row needs.
            def emit_row_offset_kept(bend)
              value(bend.offset)
              @asm.move(:l, var(bend.row), @asm.d(1))
              @asm.add(:w, @asm.d(1), @asm.d(1)) # two bytes a row
              @asm.lea(at(bend_table(bend)), @asm.a(0))
              @asm.move(:w, @asm.d(0), @asm.idx(0, 0, 1, :w))
            end

            # Where a bend's rows are kept as a wait works them out: a word for each line of the screen.
            def bend_table(bend)
              (@bend_tables ||= {})[bend.background] ||=
                @memory.reserve("the bend of #{bend.background.inspect}", Console::GENESIS.screen_height * 2)
            end

            # The plane +plane+ shows +bg+'s bend from here on, or none: +bg+ nil for a plane left empty.
            # A game that bends nothing notes none.
            def emit_bend_shown(plane, bg)
              return if bends.empty?

              bend = bg && @plan.row_bends.bend_for(bg.name)
              place = runtime_at(Runtime::Tiles::BENDS_SHOWN, plane * 4)
              return @asm.clr(:l, place) unless bend

              @asm.lea(at(bend_table(bend)), @asm.a(0))
              @asm.move(:l, @asm.a(0), place)
            end
          end
        end
      end
    end
  end
end
