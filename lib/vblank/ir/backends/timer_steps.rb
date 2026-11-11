# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A GAME'S TIMERS, LOWERED ONCE for a console whose lowering writes machine code.
      #
      # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is doing,
      # and runs what the game gave it to do on each tick. A frame is the interpreter's sixtieth of a second,
      # so at every frame boundary a running timer gains its rate in sixtieths of a tick, and each whole
      # tick that comes to is a tick (Reference#accrue_timer). Each timer keeps when it was first started
      # (nought for never), since timers move on in the order they were first started; whether it is
      # running; its rate as whole ticks and sixtieths a frame; the sixtieths of a tick it is through; and
      # its whole ticks, coming round at 65536 as the interpreter's count does.
      #
      # All of that is sums on variables, tests and calls, which every processor writes its own way and
      # means alike, so it is here in the words ControlFlow already asks a lowering for. The Color's, the
      # Super Nintendo's, the Genesis's and the PlayStation's lowerings each still carry a copy of this
      # written before it was here; DOS's is the first to take it from here.
      #
      # WHAT THE LOWERING SUPPLIES, besides what ControlFlow lists (fresh_label, place_label, jump,
      # jump_unless, emit_value, emit_store, keep_local, statement):
      #
      #   emit_store_number(name, number)   a number written in the build into a variable
      #   emit_sum(name, operator, operand) a variable changed by a sum with an operand
      #   emit_own_routine(label) { }       a routine of the lowering's own: the label, what the block
      #                                     writes, and a return
      #   call_routine(label)               a call of one
      #   keeping_interrupted_numbers(handler) { }
      #                                     what the block writes, a handler's statements, with whatever a
      #                                     routine the handler calls keeps of its own put back after. A
      #                                     handler runs inside the game's wait, which can be in the middle
      #                                     of one of the game's routines, and the interpreter gives each
      #                                     run of a routine its own count and place in a loop
      #                                     (Reference#exec_repeat). A lowering that keeps those in fixed
      #                                     places, as all of them do, has the handler's call of that same
      #                                     routine leave them changed unless it puts them back. Optional:
      #                                     left out, the block is written as it is
      #
      # and what it does with them: #keep_timer_numbers before any code, #emit_timer_statement and
      # #timer_ticks_variable where a game names a timer, and #emit_timer_routines once, whose answer is the
      # label of the routine its runtime runs at each frame boundary, once the buttons are read and unless
      # the reader has taken the last pass it compares (Reference#advance_frame moves no timer on after it).
      module TimerSteps
        STATEMENT_KINDS = %i[timer_start timer_stop on_timer].freeze
        VALUE_KINDS = %i[timer_ticks].freeze

        NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze
        FRAMES_A_SECOND = Reference::FRAME_RATE

        # The label of the routine that moves every timer on, for a runtime to call.
        FRAME_ROUTINE = "timers frame"

        def emit_timer_statement(node)
          case node.kind
          when :timer_start then emit_timer_start(node)
          when :timer_stop then emit_store_number(timer_number(node.name, :running), 0) # Reference#exec_timer_stop: its count is kept
          when :on_timer then nil # what it runs is gathered before the program is written (LoweringPlan#tick_handlers)
          else raise ArgumentError, "no writer here for #{node.kind.inspect}"
          end
        end

        # The variable a timer's whole ticks are in (Reference#timer_ticks: nought for one never started,
        # which is what the count starts at).
        def timer_ticks_variable(name) = timer_number(name, :ticks)

        # A variable for each number of each timer, and two the routines share: how many timers have been
        # started, and how many ticks the timer being moved on crossed this frame.
        def keep_timer_numbers
          return if timers.empty?

          @timer_numbers = timers.values.to_h { |number| [number, NUMBERS.to_h { |what| [what, keep_local(:"timer#{number}_#{what}")] }] }
          @timers_started = keep_local(:timers_started)
          @timer_crossed = keep_local(:timer_crossed)
        end

        # The routines the runtime runs at each frame boundary: one for each timer, which moves it on and
        # runs its handler, and one that calls those of the running timers in the order they were first
        # started. Answers that one's label, or nil for a game with no timers.
        def emit_timer_routines
          return nil if timers.empty?

          timers.each_key { |name| emit_timer_routine(name) }
          emit_own_routine(FRAME_ROUTINE) do
            (1..timers.size).each do |place_in_order|
              timers.each_key do |name|
                skip = fresh_label("not_this_one")
                jump_unless(Build.binop(:==, Build.var_ref(timer_number(name, :order)), Build.int(place_in_order)), skip)
                jump_unless(Build.var_ref(timer_number(name, :running)), skip)
                call_routine(timer_label(name))
                place_label(skip)
              end
            end
          end
          FRAME_ROUTINE
        end

        private

        def keeping_interrupted_numbers(_handler) = yield

        def timers = @plan.timers
        def timer_number(name, what) = @timer_numbers.fetch(timers.fetch(name)).fetch(what)
        def timer_label(name) = "timer #{name} frame"

        # Reference#exec_timer_start: running at its rate, its count from nought, and, the first time,
        # given its place in the order the timers move on in.
        def emit_timer_start(node)
          order = timer_number(node.name, :order)
          started = fresh_label("started_before")
          jump_unless(Build.binop(:==, Build.var_ref(order), Build.int(0)), started)
          emit_sum(@timers_started, :+, Build.int(1))
          emit_value(Build.var_ref(@timers_started))
          emit_store(order)
          place_label(started)
          whole, part = node.hz.divmod(FRAMES_A_SECOND)
          { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
            emit_store_number(timer_number(node.name, what), number)
          end
        end

        # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run once for
        # each. How many that is is settled before the first of them runs, so a handler that stops or
        # restarts its own timer still finishes the ticks this frame crossed.
        def emit_timer_routine(name)
          parts = timer_number(name, :parts)
          ticks = timer_number(name, :ticks)
          sixtieths = Build.binop(:+, Build.var_ref(parts), Build.var_ref(timer_number(name, :part_rate)))
          rate = Build.int(FRAMES_A_SECOND)
          handler = @plan.tick_handlers[name]
          emit_own_routine(timer_label(name)) do
            emit_value(Build.binop(:+, Build.var_ref(timer_number(name, :whole_rate)), Build.binop(:/, sixtieths, rate)))
            emit_store(@timer_crossed)
            emit_value(Build.binop(:%, sixtieths, rate))
            emit_store(parts)
            emit_value(Build.binop(:&, Build.binop(:+, Build.var_ref(ticks), Build.var_ref(@timer_crossed)), Build.int(0xFFFF)))
            emit_store(ticks)
            next unless handler

            top = fresh_label("tick")
            done = fresh_label("ticks_done")
            place_label(top)
            jump_unless(Build.binop(:>, Build.var_ref(@timer_crossed), Build.int(0)), done)
            keeping_interrupted_numbers(handler) { handler.children.each { |child| statement(child) } }
            emit_sum(@timer_crossed, :-, Build.int(1))
            jump(top)
            place_label(done)
          end
        end
      end
    end
  end
end
