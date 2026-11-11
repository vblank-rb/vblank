# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        class Lowering
          # THE DATE AND TIME, READ AND SET FOR THE GAME. Mixed into Lowering.
          #
          # A PC always has a clock, so `clock.present?` is always so. The runtime keeps the clock's own time
          # (Runtime::Clock: the date it read as the program started, and the seconds counted on since that
          # date's midnight) and whether its battery kept it, which is `clock.set?`.
          #
          # WHAT THE GAME READS is worked out from that by a routine written once, as the game's own
          # statements (IR::ClockCalendar), which this lowering lowers like any others: the date as a count
          # of days, the time the game set added on (IR::Clock::OFFSET_DAYS, kept in two of the game's saved
          # numbers), and the count turned back into a date. It runs as the game starts, once the saved
          # offset is read back, after the game sets a time, and after a wait when the clock's second has
          # moved: ten divisions are not spent on the passes of a second that would come to the same.
          #
          # SETTING THE CLOCK keeps how far the time set is from the clock's own, as on every console, and
          # leaves the chip alone. A clock whose battery did not keep the time is set from then on.
          module Clock
            STATEMENT_KINDS = %i[set_clock].freeze
            VALUE_KINDS = %i[clock].freeze

            # The routine that works the readings out, and its way in for after a wait.
            WORK_OUT = "clock readings"
            WHEN_MOVED = "clock readings when moved"

            # What working the readings out and setting the clock work in, with the clock's own second the
            # readings were last worked out at.
            WORK = %i[days into_day year month day hour minute second worked_at].freeze
            CALENDAR = %i[cycles of_cycle years into months].freeze

            # The clock's own, by the names the statements here read them: the runtime's own numbers.
            OWN = Ractor.make_shareable({ year: Runtime::Clock::YEAR, month: Runtime::Clock::MONTH, day: Runtime::Clock::DAY,
                                          seconds: Runtime::Clock::SECONDS, kept: Runtime::Clock::KEPT })

            # Whether +program+ reads or sets the clock, and so carries the runtime's part of it.
            def self.used_by?(program) = program.walk.any? { |node| %i[clock set_clock].include?(node.kind) }

            def clock? = @clock_used

            private

            def keep_clock_readings
              @clock_sets = IR::Clock.sets_clock?(@program)
              @clock_used = Clock.used_by?(@program)
              return unless @clock_used

              (IR::Clock::TIME + [:set]).each { |part| @locals[clock_kept(part)] = @memory.reserve("the clock's #{part}", 4) }
              (WORK + CALENDAR).each { |part| @locals[clock_work(part)] = @memory.reserve("the clock's working #{part}", 4) }
              OWN.each { |part, name| @locals[clock_own(part)] = @memory[name] }
            end

            def clock_kept(part) = :"clock.#{part}"
            def clock_work(part) = :"clock.working #{part}"
            def clock_own(part) = :"clock.own #{part}"

            # Before the game's first line.
            def emit_clock_at_start
              @asm.call(WORK_OUT) if @clock_used
            end

            # After each wait: the clock moved on by the frames it took, and the readings with it.
            def emit_clock_each_pass
              return unless @clock_used

              @asm.call("rt_clock_tick")
              @asm.call(WHEN_MOVED)
            end

            # The readings worked out again once the saved offset is read back.
            def emit_clock_readings_from_save
              @asm.call(WORK_OUT) if @clock_sets
            end

            def emit_clock_reading(node)
              return @asm.mov(:eax, 1) if node.reading == :present

              @asm.mov(:eax, number_at(clock_kept(node.reading)))
            end

            # THE READINGS WORKED OUT: nothing (every reading stays nought) while the clock was never set, and
            # otherwise the clock's own day and time with the offset added, a day carried when the seconds
            # pass midnight, back to a date and a time.
            def emit_clock_routines
              return unless @clock_used

              done = fresh_label("clock_readings_done")
              own = ->(part) { Build.var_ref(clock_own(part)) }
              @asm.label(WHEN_MOVED)
              emit_jump_unless(Build.binop(:!=, own[:seconds], Build.var_ref(clock_work(:worked_at))), done)
              @asm.label(WORK_OUT)
              emit_statement(Build.set(clock_work(:worked_at), own[:seconds]))
              emit_statement(Build.set(clock_kept(:set), own[:kept]))
              emit_jump_unless(Build.var_ref(clock_kept(:set)), done)
              work_out_statements.each { |statement| emit_statement(statement) }
              @asm.label(done)
              @asm.ret
            end

            # The time the game set, as how far it is from the clock's own; nought for a game that sets none.
            def clock_offset(name) = @clock_sets ? Build.var_ref(name) : Build.int(0)

            def work_out_statements
              days = clock_work(:days)
              into_day = clock_work(:into_day)
              own = ->(part) { Build.var_ref(clock_own(part)) }
              copy = IR::Clock::TIME.to_h { |reading| [reading, clock_kept(reading)] }
              into = Build.var_ref(into_day)
              [
                Build.set(days, Build.binop(:+, ClockCalendar.day_number(own[:year], own[:month], own[:day]),
                                            clock_offset(IR::Clock::OFFSET_DAYS))),
                Build.set(into_day, Build.binop(:+, own[:seconds], clock_offset(IR::Clock::OFFSET_SECONDS))),
                Build.set(days, Build.binop(:+, Build.var_ref(days), Build.binop(:/, into, Build.int(IR::Clock::SECONDS_A_DAY)))),
                Build.set(into_day, Build.binop(:%, into, Build.int(IR::Clock::SECONDS_A_DAY))),
                *ClockCalendar.date_of_day_number(days, into: copy, scratch: CALENDAR.to_h { |part| [part, clock_work(part)] }),
                Build.set(copy[:hour], Build.binop(:/, into, Build.int(3600))),
                Build.set(copy[:minute], Build.binop(:%, Build.binop(:/, into, Build.int(60)), Build.int(60))),
                Build.set(copy[:second], Build.binop(:%, into, Build.int(60)))
              ]
            end

            # SETTING THE CLOCK, as Reference#exec_set_clock does: each part worked out once, in order; how far
            # the time set is from the clock's own, in days and the seconds left over; the clock set from now
            # on; and the readings worked out from it.
            def emit_set_clock(node)
              { year: node.year, month: node.month, day: node.day, hour: node.hour, minute: node.minute,
                second: node.second }.each { |part, value| emit_statement(Build.set(clock_work(part), value)) }
              offset_statements.each { |statement| emit_statement(statement) }
              emit_statement(Build.set(clock_own(:kept), Build.int(1)))
              @asm.call(WORK_OUT)
            end

            # The clock's own seconds count on past midnight, so its own day is its date's and the whole days
            # in those seconds, and its own time of day what is left of them.
            def offset_statements
              days = IR::Clock::OFFSET_DAYS
              seconds = IR::Clock::OFFSET_SECONDS
              a_day = Build.int(IR::Clock::SECONDS_A_DAY)
              work = ->(part) { Build.var_ref(clock_work(part)) }
              own = ->(part) { Build.var_ref(clock_own(part)) }
              own_days = Build.binop(:+, ClockCalendar.day_number(own[:year], own[:month], own[:day]),
                                     Build.binop(:/, own[:seconds], a_day))
              borrow = Build.binop(:<, Build.var_ref(seconds), Build.int(0))
              [
                Build.set(days, Build.binop(:-, ClockCalendar.day_number(work[:year], work[:month], work[:day]), own_days)),
                Build.set(seconds, Build.binop(:-, ClockCalendar.seconds_into_day(work[:hour], work[:minute], work[:second]),
                                               Build.binop(:%, own[:seconds], a_day))),
                Build.set(days, Build.binop(:-, Build.var_ref(days), borrow)),
                Build.set(seconds, Build.binop(:+, Build.var_ref(seconds), Build.binop(:*, borrow, a_day)))
              ]
            end
          end
        end
      end
    end
  end
end
