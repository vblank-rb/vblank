# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Which code the game runs from an interrupt can use the copying engine (DMA3) or the
        # fill's colour word (Primitives::FILL_SCRATCH): a timer's `on_tick` body, or a bend worked
        # out a line at a time, and the routines either calls (TopOfQuickMemory.interrupt_bodies).
        #
        # Such code can land between the game's writes to the engine, or between a fill's colour
        # and its rows, so the game's copies are held (Primitives#with_copy_setup_held) and the
        # handler saves the colour word around itself. A game whose interrupts only count or
        # compute pays for neither, and builds the same bytes as one with no interrupt code.
        #
        # The answer is read off the program, so it errs one way only: a statement of any kind
        # not listed below counts as copying, so a new kind that copies is held until it is listed.
        module InterruptCopies
          # The statements and values whose Advance lowering never starts the copying engine nor
          # writes the fill's colour word: arithmetic, tests, loops, calls, single list slots and
          # the timers. Each is lowered by the processor alone (Statements, Expressions, Lists,
          # Timers). A routine a call reaches is read too, so `call` is only the jump.
          QUIET_KINDS = %i[
            set add sub copy negate abs negate_abs clamp if loop repeat every after call call_one_of
            case halt list_push list_drop list_set timer_start timer_stop on_timer scroll_rows func
            int var_ref neg bit_not absolute clamped binop mul_fix div_fix shift_right held pressed
            pulled players_connected local_player chance pixels_overlap data_byte table_get list_get
            list_len timer_ticks
          ].freeze

          module_function

          # Whether any code the game runs from an interrupt can copy or fill.
          def any?(program) = bodies(program).any? { |body| copies?(program, body) }

          # Whether the rows worked out a line at a time, from the interrupt after each line the
          # display draws, can copy or fill (Raster#emit_row_bend_handler). Never in a game with a
          # frame, whose rows are worked out after the game wakes from its wait.
          def lines_copy?(program)
            BendForm.rows_per_scanline?(program) &&
              bodies(program).any? { |body| body.kind != :on_timer && copies?(program, body) }
          end

          # The code run from an interrupt: TopOfQuickMemory.interrupt_bodies, and in a game whose
          # rows are worked out a line at a time, the light's block too, which runs beside the bends.
          def bodies(program)
            lights = BendForm.rows_per_scanline?(program) ? program.walk.select { |node| node.kind == :shade_outside } : []
            TopOfQuickMemory.interrupt_bodies(program) + lights
          end

          # Whether +body+ (a timer's handler or a bend), or a routine it calls, can copy or fill.
          def copies?(program, body)
            funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            routines = Reach.routines_called_from(program, [body]).map { |name| funcs.fetch(name) }
            Reach.statements_from(body, *routines).any? { |node| !QUIET_KINDS.include?(node.kind) }
          end
        end
      end
    end
  end
end
