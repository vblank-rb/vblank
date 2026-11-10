# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # A ROUTINE THAT STOPS FOR A FRAME AND CARRIES ON, written so that where it stopped is data.
        #
        # A game waits for the next frame wherever it likes: in its game loop, in a scene's own
        # loop, two routines deep. Kept on the machine's stack, or in a language's own paused calls,
        # the place a game has reached cannot be written to a file, and so cannot be saved part way
        # and loaded back (a save state).
        #
        # So every routine that can reach a wait (#resumable_names) is cut into numbered STEPS (Statements::Steps),
        # and keeps the number of the step it is on in a global of its own, its counter. A wait ends
        # its step: the counter is set to the step after, and the routine hands back 1, waiting
        # (Statements::Pause). A call of another such routine starts a step of its own, so when the callee hands
        # back 1 the caller hands back 1 too (Statements::Resume), and when it is called again it calls the
        # callee again, which carries on from its own counter. The driver plays the game by calling the
        # main routine once a frame until it hands back 0. A routine's locals become globals of its own,
        # since a step after a wait still reads them; no routine calls itself (LoweringPlan refuses
        # it), so one of each is enough.
        #
        # So between frames the whole place a game has reached is in its globals, and a game whose
        # globals are written out and read back into a fresh run plays on as the first would have.
        #
        # ONLY WHAT HOLDS A WAIT IS CUT. A loop, a branch or a block with no wait in it, however
        # deep, stays as it was inside the step it is in, so a game's inner loops cost what they did.
        # A routine that never waits is not touched at all.
        #
        # A ROUTINE RUN FOR AN ANSWER. The runtime asks the game for answers between frames (a timer's
        # tick, a bend's lines), and such a routine cannot wait; one of the game's resumable routines
        # it calls runs from its start to its end, as the interpreter runs it. The game may be stopped
        # inside that very routine, so the call keeps the counters and locals of every resumable
        # routine it can reach, runs from step 0, and puts them back (Statements::RunToEnd).
        #
        # One transform of the statement tree, before any printer sees it: the C, JavaScript and Ruby
        # printers each print the steps their own way, and none of them has to know which routines
        # wait.
        class Resumable

          WAIT = "rg_wait_vblank"
          CALL_ROUTINE = "rg_call_routine"
          MAIN = "rg_game_main"
          # What a wait in a routine that answers the runtime becomes: a fault, as the answer is wanted now.
          WAIT_WHILE_ANSWERING = "rg_wait_vblank_while_answering"

          # +items+ is the file's top level (Lowering#top_level).
          def initialize(items)
            @items = items
            @functions = items.grep(Statements::Function).to_h { |function| [function.name.text, function] }
            @tables = items.grep(Statements::FunctionTable).to_h { |table| [table.name.text, table.functions.map(&:text)] }
            @resumable = resumable_names
            @cuts = @resumable.select { |name| @functions.key?(name) }.to_h { |name| [name, cut_routine(name)] }
          end

          # The top level with every routine that can wait made resumable, and the globals their
          # counters and locals are kept in added before the first routine.
          def items
            rewritten = @items.map do |item|
              case item
              when Statements::Function then rewritten_routine(item)
              when Statements::Prototype then item.with(resumable: @resumable.include?(item.name.text))
              when Statements::FunctionTable then item.with(resumable: item.functions.any? { |name| @resumable.include?(name.text) })
              else item
              end
            end
            first_routine = rewritten.index { |item| [Statements::Prototype, Statements::Function, Statements::FunctionTable].include?(item.class) }
            rewritten.insert(first_routine || rewritten.length, *step_globals)
          end

          private

          # One routine cut into steps: its counter, its steps and its locals, now globals.
          CutRoutine = Data.define(:counter, :steps, :locals)

          def counter_of(function_name) = Statements::Name.new(text: "#{function_name}_step")

          # --- which routines can wait ---

          # Every routine that can reach a wait, found by following calls until nothing more joins. A
          # routine in an array with one that waits waits too, since a call through the array cannot
          # tell which it reaches. The main routine always is one, so the driver plays every game the
          # same way; a routine the runtime calls for an answer (exported) never is.
          def resumable_names
            names = Set[MAIN]
            loop do
              joining = @functions.each_value.select do |function|
                !function.exported && !names.include?(function.name.text) && reaches_wait?(function.body, names)
              end.map { |function| function.name.text }
              joining += @tables.values.select { |members| members.any? { |member| names.include?(member) } }.flatten
              joining.reject! { |name| names.include?(name) }
              break if joining.empty?

              names.merge(joining)
            end
            names
          end

          # Whether any of +statements+ holds a place a routine stops at, the routines in +names+ being
          # the ones that can.
          def reaches_wait?(statements, names = @resumable)
            statements.any? do |statement|
              case statement
              when Statements::Eval then call_waits?(statement.call, names)
              when Statements::If then reaches_wait?(statement.body, names) || reaches_wait?(statement.otherwise, names)
              when Statements::While, Statements::Block then reaches_wait?(statement.body, names)
              else false
              end
            end
          end

          # Whether a call, written as a statement, can wait: the wait itself, a routine that can, or a
          # routine picked from an array that holds one.
          def call_waits?(call, names = @resumable)
            name = call.function.text
            return true if name == WAIT
            return Array(table_of(call)).any? { |member| names.include?(member) } if name == CALL_ROUTINE

            @functions.key?(name) && !@functions[name].exported && names.include?(name)
          end

          # The routines an array call (rg_call_routine(table[which])) picks among.
          def table_of(call) = @tables[call.args.first.array.text]

          # The resumable routines a call can reach: the one it names (or each it can pick from an
          # array), and every one those call in turn.
          def resumable_reached_by(call)
            reached = Set.new
            pending = resumable_named_by(call)
            until pending.empty?
              name = pending.shift
              next unless reached.add?(name)

              pending.concat(resumable_calls_in(@functions.fetch(name).body))
            end
            reached
          end

          def resumable_named_by(call)
            return [] if call.function.text == WAIT
            return Array(table_of(call)).select { |member| @resumable.include?(member) } if call.function.text == CALL_ROUTINE

            @resumable.include?(call.function.text) ? [call.function.text] : []
          end

          def resumable_calls_in(statements)
            statements.flat_map do |statement|
              case statement
              when Statements::Eval then resumable_named_by(statement.call)
              when Statements::If then resumable_calls_in(statement.body) + resumable_calls_in(statement.otherwise)
              when Statements::While, Statements::Block then resumable_calls_in(statement.body)
              else []
              end
            end
          end

          # --- the routines ---

          def cut_routine(name)
            counter = counter_of(name)
            cut = Cut.new(counter, ->(statement) { reaches_wait?([statement]) })
            steps = cut.steps_of(@functions.fetch(name).body)
            # The lowering numbers every local across the whole file (Lowering#local_name), so a local's
            # name is already its routine's alone; uniq for one declared in two blocks of one routine.
            CutRoutine.new(counter: counter, steps: steps, locals: cut.locals.uniq(&:name))
          end

          # The counters and locals of every resumable routine, as globals.
          def step_globals
            @cuts.values.flat_map do |cut|
              [Statements::Global.new(name: cut.counter), *cut.locals.map { |local| Statements::Global.new(name: local.name, type: local.type) }]
            end
          end

          def rewritten_routine(function)
            name = function.name.text
            return function.with(body: answer_body(function.body)) if function.exported && name != MAIN

            cut = @cuts[name]
            return function unless cut

            function.with(body: [Statements::Steps.new(counter: cut.counter, steps: cut.steps)], resumable: true)
          end

          # A routine the runtime calls for an answer, which cannot wait: a wait in it is a fault, and a
          # resumable routine it calls is run from its start to its end (Statements::RunToEnd).
          def answer_body(statements)
            statements.map do |statement|
              case statement
              when Statements::Eval then answer_call(statement)
              when Statements::If then statement.with(body: answer_body(statement.body), otherwise: answer_body(statement.otherwise))
              when Statements::While, Statements::Block then statement.with(body: answer_body(statement.body))
              else statement
              end
            end
          end

          def answer_call(statement)
            call = statement.call
            return Statements::Eval.new(call: Statements::Call.new(function: Statements::Name.new(text: WAIT_WHILE_ANSWERING))) if call.function.text == WAIT
            return statement unless call_waits?(call)

            cuts = resumable_reached_by(call).map { |name| @cuts.fetch(name) }
            Statements::RunToEnd.new(call: call, counters: cuts.map(&:counter), locals: cuts.flat_map(&:locals))
          end

          # ONE ROUTINE CUT INTO STEPS. Steps are numbered as they are made, from 0, and each is a
          # list of statements ending in a Goto, a Pause or a Finish.
          class Cut
            # The routine's locals (Statements::Local), each kept in a global of its own now.
            attr_reader :locals

            # +counter+ names the routine's counter; +holds_wait+ answers whether a statement holds a
            # place the routine stops at.
            def initialize(counter, holds_wait)
              @counter = counter
              @holds_wait = holds_wait
              @steps = [[]]
              @step = 0
              @locals = []
            end

            # The steps of a routine whose body is +statements+.
            def steps_of(statements)
              append_statements(statements, nil)
              append(Statements::Finish.new(counter: @counter))
              @steps
            end

            private

            def new_step
              @steps << []
              @steps.length - 1
            end

            def append(statement) = @steps[@step] << statement
            def open_step(step) = @step = step
            def goto_step(step) = Statements::Goto.new(counter: @counter, step: step)

            # +loop_end+ is the step a Break here goes on at: the end of the cut loop it is in.
            def append_statements(statements, loop_end)
              statements.each { |statement| append_statement(statement, loop_end) }
            end

            def append_statement(statement, loop_end)
              return append(uncut_statement(statement, loop_end, in_loop: false)) unless @holds_wait.call(statement)

              case statement
              when Statements::Eval then append_stop(statement)
              when Statements::If then append_branch(statement, loop_end)
              when Statements::While then append_loop(statement)
              when Statements::Block then append_statements(statement.body, loop_end)
              end
            end

            # A wait ends its step; a call of a resumable routine starts one, so the call is made again
            # when the routine carries on.
            def append_stop(statement)
              step = new_step
              if statement.call.function.text == WAIT
                append(statement)
                append(Statements::Pause.new(counter: @counter, step: step))
                open_step(step)
              else
                append(goto_step(step))
                open_step(step)
                append(Statements::Resume.new(call: statement.call))
              end
            end

            def append_branch(statement, loop_end)
              taken = new_step
              other = statement.otherwise.empty? ? nil : new_step
              after = new_step
              append(Statements::If.new(condition: statement.condition, body: [goto_step(taken)], otherwise: [goto_step(other || after)]))
              open_step(taken)
              append_statements(statement.body, loop_end)
              append(goto_step(after))
              if other
                open_step(other)
                append_statements(statement.otherwise, loop_end)
                append(goto_step(after))
              end
              open_step(after)
            end

            def append_loop(statement)
              head = new_step
              body = new_step
              after = new_step
              append(goto_step(head))
              open_step(head)
              append(Statements::If.new(condition: statement.condition, body: [goto_step(body)], otherwise: [goto_step(after)]))
              open_step(body)
              append_statements(statement.body, after)
              append(goto_step(head))
              open_step(after)
            end

            # A statement with no wait in it, as it was but for what the cut changes: a local is a
            # global now, a return finishes the routine, and a break out of a loop that was cut goes on
            # at that loop's end (one inside a loop kept whole is that loop's own).
            def uncut_statement(statement, loop_end, in_loop:)
              case statement
              when Statements::Local
                @locals << statement
                Statements::Assign.new(target: statement.name, value: statement.value)
              when Statements::Return then Statements::Finish.new(counter: @counter)
              when Statements::Break then in_loop ? statement : goto_step(loop_end)
              when Statements::If
                statement.with(body: uncut_statements(statement.body, loop_end, in_loop),
                               otherwise: uncut_statements(statement.otherwise, loop_end, in_loop))
              when Statements::While then statement.with(body: uncut_statements(statement.body, loop_end, true))
              when Statements::Block then statement.with(body: uncut_statements(statement.body, loop_end, in_loop))
              else statement
              end
            end

            def uncut_statements(statements, loop_end, in_loop)
              statements.map { |statement| uncut_statement(statement, loop_end, in_loop: in_loop) }
            end
          end
        end
      end
    end
  end
end
