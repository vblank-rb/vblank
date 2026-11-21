# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Code the game did not call, which can call a routine the game is part way through, and the
        # state each call of that routine keeps to itself.
        #
        # Three kinds of code run where the game wrote no call:
        #
        # - a bend's steps, worked out as the game wakes from a wait (Raster#emit_fill_row_bend_tables);
        # - a timer's handler, run from the timer's interrupt, which comes between any two
        #   instructions of the game (GBA#emit_irq_handler);
        # - a timer's handler that waits, itself or in a routine it calls, run as the game wakes from
        #   a wait (below).
        #
        # Each can call a routine the game is inside: waiting in it, or, for an interrupt, anywhere in
        # it. The interpreter keeps each call's loop counts, and the scene each `case` read, to itself
        # (Reference#exec_repeat, #exec_case), so the call that was interrupted goes on from its own
        # turn. The cartridge keeps those in fixed places: a loop's count in two registers or the
        # quick memory (GBA::LoopForm), a `case`'s reading in the quick memory (Functions#emit_case),
        # and the second call writes over them. So that code saves them on the stack while it runs
        # and restores them after. The interrupt saves the registers already (GBA::IRQ_SAVED_REGS),
        # so there it is the memory alone. A game with none of this has no code here.
        #
        # A handler that waits cannot run in the interrupt. While the console runs an interrupt's
        # routine it holds every other interrupt off, the screen's included, so a wait there never
        # ends and the game stops. So such a handler is a routine of its own, run where the
        # interpreter runs every handler: as the game wakes from a wait, once for each tick since the
        # last time (Reference#accrue_timer). Its interrupt only counts the tick. The handler's own
        # wait is a wait like any other, so the handler runs again inside it, as on the interpreter.
        class FrameBoundaryCalls
          include Console::Hardware

          # What one kind of code saves around itself: the game's variables in the quick memory, and
          # whether the two loop registers too.
          SavedState = Data.define(:vars, :registers) do
            def self.none = new(vars: [], registers: false)

            def empty? = vars.empty? && !registers

            # The stack it takes, a word each.
            def bytes = (vars.size + (registers ? 2 : 0)) * 4
          end

          # Worked out from the program alone: the handlers that wait, by timer, with what is saved
          # around running them; what is saved around the bends; and what each handler run from the
          # interrupt saves, by timer. +last_pass_reads+ are the game's variables a handler that waits
          # reads as the last pass left them, which the game wakes to new values in (#emit_waiting_handlers).
          Plan = Data.define(:waiting, :for_waiting, :last_pass_reads, :for_bends, :for_handler) do
            def self.none = new(waiting: {}, for_waiting: SavedState.none, last_pass_reads: [], for_bends: SavedState.none,
                                for_handler: {})
          end

          # +program+'s Plan.
          def self.plan(program)
            handlers = IR::Nodes::OnTimer.of(program)
            bends = program.walk.select { |node| node.kind == :scroll_rows }
            return Plan.none if handlers.empty? && bends.empty?

            lowering_plan = LoweringPlan.new(program, console: Console::ADVANCE, error: LoweringError)
            funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            unread = LoopForm.unread_indexes(program)
            reentered = lowering_plan.routines_reentered_at_frame_boundary
            waiting = lowering_plan.tick_handlers_waiting
            bodies = ->(names) { names.map { |name| funcs.fetch(name) } }

            bend_routines = Reach.routines_called_from(program, bends)
            for_bends = SavedState.new(
              vars: state_vars_in(bodies.call(bend_routines & reentered), unread),
              registers: Reach.statements_from(*bends, *bodies.call(bend_routines)).any? { |node| LoopForm.needs_loop_registers?(node) }
            )
            waiting_routines = Reach.routines_called_from(program, waiting.values) & reentered
            for_waiting = SavedState.new(vars: state_vars_in(waiting.values + bodies.call(waiting_routines), unread),
                                         registers: true)

            # An interrupt can come anywhere, so a routine its handler calls is saved whenever anything
            # else can be part way through it: the game, a bend, or a handler run as the game wakes.
            # Not another interrupt's: the console runs one at a time.
            elsewhere = Reach.routines(program, also: bends + waiting.values)
            for_handler = handlers.reject { |timer, _| waiting.key?(timer) }.to_h do |timer, handler|
              shared = Reach.routines_called_from(program, [handler]) & elsewhere
              [timer, SavedState.new(vars: state_vars_in(bodies.call(shared), unread), registers: false)]
            end
            reads = [IR::Frames::STEP] + (GBA.reads_button_edges?(program) ? [KEYS_PRESSED] : [])
            Plan.new(waiting: waiting, for_waiting: for_waiting, last_pass_reads: waiting.empty? ? [] : reads,
                     for_bends: for_bends, for_handler: for_handler)
          end

          # The game's variables the loops and `case`s under +roots+ keep a call's state in, by the
          # shape each loop is given (Statements#emit_repeat; +unread+ is LoopForm.unread_indexes).
          # A loop counting in the two registers keeps nothing there. One bracketing a statement
          # writes its index out for the statement to read. One in memory keeps its index, which is
          # the passes left when it counts down, and its limit when it counts up.
          def self.state_vars_in(roots, unread)
            Reach.statements_from(*roots).flat_map do |node|
              next [Functions.picked_var(node.var)] if node.kind == :case
              next [] unless node.kind == :repeat

              read = !unread.include?(node.index)
              if LoopForm.counter_in_registers?(node) then []
              elsif LoopForm.spills?(node) then read ? [node.index] : []
              elsif read then [node.index, Statements.limit_var(node.index)]
              else [node.index]
              end
            end.uniq
          end
          private_class_method :state_vars_in

          def initialize(emitter:, primitives:, lowering:, functions:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @functions = functions
            @plan = Plan.none
          end

          # Works out +program+'s Plan, and makes each handler that waits a routine.
          def prepare(program)
            @plan = FrameBoundaryCalls.plan(program)
            @plan.waiting.each do |timer, handler|
              @functions.define_generated_func(routine_for(timer)) do
                handler.children.each { |child| @lowering.statement(child) }
              end
            end
          end

          # Whether +timer+'s handler waits, and so runs as the game wakes rather than in the interrupt.
          def answered_at_wait?(timer) = @plan.waiting.key?(timer)

          # In the interrupt, for a handler that waits: one more tick to answer.
          def emit_tick_seen(timer)
            @primitives.load_var(ACC, seen_var(timer))
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, seen_var(timer))
          end

          # In the interrupt, for a handler that does not wait: its body, with the state of the
          # routines it shares with the rest of the game saved.
          def with_handler_state_saved(timer, &)
            emit_saving(@plan.for_handler.fetch(timer, SavedState.none), &)
          end

          # Whether any timer's handler waits.
          def handlers_wait? = @plan.waiting.any?

          # What a handler that waits reads is what the game's last pass read. The interpreter runs
          # the handlers as a frame ends, before it counts that frame and reads the buttons
          # (Reference#advance_frame), so a handler reads the frames since power-on, the frames the
          # last pass took and the buttons pressed as the pass that just ended read them. The
          # cartridge counts the frame and reads the buttons as the game wakes (Frames#emit_frame_step,
          # Expressions#emit_latch_presses), so what those write is pushed first, as the wait ends,
          # and put back while the handlers run (#emit_waiting_handlers): the Plan's last_pass_reads,
          # then the mark the frames are measured from, which is nearest the top.
          def emit_push_last_pass_reads
            return unless handlers_wait?

            last_pass_pushed.each do |name|
              @primitives.load_var(ACC, name)
              @emitter.emit(ASM.push(ACC))
            end
          end

          # As the game wakes from a wait: every handler that waits, once for each tick since this
          # last ran. The count is taken in one go and kept on the stack, so a run of the handler
          # that waits, and so comes back here, runs only for the ticks that came after. Only the
          # interrupt adds to the ticks seen and only this writes the ticks answered, so a tick that
          # comes between the two reads is answered next time rather than lost.
          #
          # The handlers run with what the last pass read (#emit_push_last_pass_reads): this pass's
          # are pushed, the last pass's put in their place, and this pass's put back after. So are
          # the frames since power-on: this pass's frames are taken off the count while the handlers
          # run and put back after. The screen's interrupt adds to that count, so it is held off for
          # the three instructions of each change, and a frame that ends meanwhile is counted as it
          # is let back on. The mark is set to the count as they end, as the interpreter sets it
          # after its handlers, so the next pass is measured from there.
          def emit_waiting_handlers
            return unless handlers_wait?

            reads = @plan.last_pass_reads
            saved = @plan.for_waiting
            emit_saving(saved) do
              reads.each do |name|
                @primitives.load_var(ACC, name)
                @emitter.emit(ASM.push(ACC)) # this pass's
              end
              last_pass_top = saved.bytes + (4 * reads.size)
              @emitter.emit(ASM.ldr_offset(TMP, STACK, last_pass_top)) # the last pass's mark
              @primitives.load_var(ACC, IR::Frames::SEEN)
              @emitter.emit(ASM.sub_reg(SPARE, ACC, TMP))
              @emitter.emit(ASM.push(SPARE)) # this pass's frames, taken off the count
              @primitives.store_var(TMP, IR::Frames::SEEN)
              reads.each do |name|
                @emitter.emit(ASM.ldr_offset(TMP, STACK, last_pass_top + 4 + last_pass_offset(name)))
                @primitives.store_var(TMP, name)
              end
              emit_frame_count_change(:sub)

              @plan.waiting.each_key { |timer| emit_handler_runs(timer) }

              @emitter.emit(ASM.pop(SPARE))
              emit_frame_count_change(:add)
              @primitives.load_var(ACC, IR::Frames::COUNT)
              @primitives.store_var(ACC, IR::Frames::SEEN)
              reads.reverse_each do |name|
                @emitter.emit(ASM.pop(ACC))
                @primitives.store_var(ACC, name)
              end
            end
            @emitter.emit(ASM.add_imm(STACK, STACK, 4 * last_pass_pushed.size))
          end

          # The block, which works the bends out, with the state it can write over saved: that of the
          # routines its steps call that can be waiting here, and the two registers a loop counts in,
          # where the steps can reach code that uses them.
          def with_bend_state_saved(&)
            emit_saving(@plan.for_bends, &)
          end

          private

          # What #emit_push_last_pass_reads pushes, in order: the last pass's reads, then the mark.
          def last_pass_pushed = @plan.last_pass_reads + [IR::Frames::SEEN]

          # How far below the mark, at the top, the last pass's +name+ is on the stack.
          def last_pass_offset(name) = 4 * (last_pass_pushed.size - 1 - last_pass_pushed.index(name))

          # The frames in spare taken off (+op+ :sub) or put back on (:add) the frames since power-on,
          # with the interrupts held off so the screen's cannot count a frame between the read and
          # the write and have it lost. One held off meanwhile runs as they are let back on.
          def emit_frame_count_change(op)
            @emitter.write_reg16(REG_IME, 0)
            @primitives.load_var(ACC, IR::Frames::COUNT)
            @emitter.emit(op == :sub ? ASM.sub_reg(ACC, ACC, SPARE) : ASM.add_reg(ACC, ACC, SPARE))
            @primitives.store_var(ACC, IR::Frames::COUNT)
            @emitter.write_reg16(REG_IME, 1)
          end

          # A run of +timer+'s handler routine for every tick its interrupt has seen since this last
          # ran, the count of runs left on the stack across each.
          def emit_handler_runs(timer)
            top = @emitter.gensym
            none = @emitter.gensym
            @primitives.load_var(ACC, seen_var(timer))
            @primitives.load_var(TMP, answered_var(timer))
            @primitives.store_var(ACC, answered_var(timer))
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :eq)
            @emitter.place_label(top)
            @emitter.emit(ASM.push(ACC))
            @lowering.statement(Build.call(routine_for(timer)))
            @emitter.emit(ASM.pop(ACC))
            @emitter.emit(ASM.subs_imm(ACC, ACC, 1))
            @emitter.emit_branch(:bcond, top, cond: :ne)
            @emitter.place_label(none)
          end

          # The block, with +saved+ pushed before it and restored after.
          def emit_saving(saved)
            return yield if saved.empty?

            @emitter.emit(ASM.push(LoopForm::COUNTER, LoopForm::LIMIT)) if saved.registers
            saved.vars.each do |name|
              @primitives.load_var(ACC, name)
              @emitter.emit(ASM.push(ACC))
            end
            yield
            saved.vars.reverse_each do |name|
              @emitter.emit(ASM.pop(ACC))
              @primitives.store_var(ACC, name)
            end
            @emitter.emit(ASM.pop(LoopForm::COUNTER, LoopForm::LIMIT)) if saved.registers
          end

          # The routine a handler that waits is made into, and the ticks its interrupt has seen and
          # the ones answered.
          def routine_for(timer) = DerivedNames.join("__ticked_", timer)
          def seen_var(timer) = DerivedNames.join("_ticks_seen_", timer)
          def answered_var(timer) = DerivedNames.join("_ticks_answered_", timer)
        end
      end
    end
  end
end
