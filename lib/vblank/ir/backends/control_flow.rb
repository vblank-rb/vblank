# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # LOOPS, TESTS AND BRANCHES, LOWERED ONCE for every console whose lowering writes machine code
      # (the Color's, the Super Nintendo's, the Genesis's and the PlayStation's).
      #
      # A test, a loop and a choice between scenes are the same few labels and jumps on every
      # processor: where the labels go and which way each jump points is the program's, and only how
      # a label, a jump and a load are written is the processor's. Written out in each lowering, the
      # four copies drifted: two of them compared a loop's count as the number written in the game and
      # two worked it out into a variable first, so the same game got a slower loop on two consoles.
      # So the walk is here, once, and a fix or a speed-up to it lands on all four.
      #
      # WHAT THE LOWERING SUPPLIES. This module is mixed into a lowering and calls these of it, each
      # written in that processor's instructions:
      #
      #   fresh_label(what)               a label no other has, named for what it marks
      #   place_label(label)              the label put where the next instruction goes
      #   jump(label)                     always
      #   jump_unless(condition, label)   when the condition does not hold
      #   jump_if(condition, label)       when it holds; a nil condition never does
      #   emit_value(operand)             the operand worked out, where emit_store finds it
      #   emit_store(name)                that number into a variable
      #   emit_store_zero(name)           nought into a variable
      #   emit_copy_variable(from, to)    one variable's number into another
      #   emit_increment(name)            a variable one bigger
      #   keep_local(what)                a variable of the routine's own, by name
      #   statement(node)                 any statement, this module's among them
      #   folded(operand)                 the number an operand is known to be while building, or nil
      #   children_of(node)               [what runs, what runs otherwise] of a statement with a body
      #   loop_statements(node)           what a game loop runs every pass, in the console's order
      #   console_loop(node), game_loops  the plan's (LoweringPlan)
      #   loop_form                       the plan's too: which shape a repeat can take (LoopForm)
      #   emit_scene(scene)               a scene's routine run, with what its arrival owes
      #
      # What a statement means is Reference's (#exec_if, #exec_repeat, #exec_case), and each console's
      # checked run holds its cartridge to that after every pass. The kinds a console draws and plays
      # with stay in its own lowering.
      module ControlFlow
        # The statements written here (Lowering#statements_written_by), each by its own method.
        STATEMENT_KINDS = %i[if loop repeat every after case].freeze

        # The numbers a routine keeps of its own for ONE CALL of it, asked for by these names through
        # keep_local: a loop's turns and its count (#emit_repeat), and the scene a `case` read
        # (#emit_case). Where a second call can come while the first is going
        # (LoweringPlan#routines_reentered_at_frame_boundary), a lowering puts them back after it.
        CALL_NUMBERS = %i[index count state].freeze

        # EVERY METHOD OF THIS MODULE A LOWERING WRITES ITS OWN WAY, by the method and then the
        # console, with why its way is cheaper there. A lowering takes the walk as it is unless it is
        # named here (.claude/rules/adding-a-backend.md); test_control_flow.rb holds the four
        # lowerings to this list, both ways. The measurement behind each is in the commit that
        # added it.
        OWN_WAYS = Ractor.make_shareable(
          {
            with_counter_held: {
              "Genesis" => "A 68000 instruction that counts or compares in a data register is a third of the time of " \
                           "the same on a place in work RAM, and a body that reads its index reads it for a quarter. " \
                           "Genesis::Lowering#with_counter_held keeps the count in D7, D6 or D5 through a loop whose " \
                           "body is written with D0 to D2 and A0 alone, and puts it back as the loop ends."
            }
          }
        )

        def emit_control_flow_statement(node)
          case node.kind
          when :if then emit_if(node)
          when :loop then emit_loop(node)
          when :repeat then emit_repeat(node)
          when :every, :after then emit_beat(node)
          when :case then emit_case(node)
          else raise ArgumentError, "no writer here for #{node.kind.inspect}"
          end
        end

        # A test whose answer is known while building keeps only the side that runs.
        def emit_if(node)
          body, otherwise = children_of(node)
          known = folded(node.cond)
          return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

          other = fresh_label("else")
          done = fresh_label("end_if")
          jump_unless(node.cond, other)
          body.each { |child| statement(child) }
          jump(done) unless otherwise.empty?
          place_label(other)
          otherwise.each { |child| statement(child) }
          place_label(done)
        end

        # A game loop: what comes before its first pass, a note of which loop is running where a
        # halt needs it (#keep_loop_running), and its passes for ever.
        def emit_loop(node)
          console_loop(node).before.each { |child| statement(child) }
          statement(Build.set(@loop_running, (loops_ending_passes.index(node) || -1) + 1)) if @loop_running
          top = fresh_label("loop")
          place_label(top)
          loop_statements(node).each { |child| statement(child) }
          jump(top)
        end

        # The game loops that end each pass by placing the display's writes
        # (IR::Frames::ConsoleLoop#pass_end), which a halt has to end as the running one does.
        def loops_ending_passes
          @loops_ending_passes ||= game_loops.select { |node| console_loop(node).pass_end.any? }
        end

        # Which of those is running, counted from 1, and nought for none, in a game with any: a
        # halt can be anywhere, in a routine called from any loop or from none.
        def keep_loop_running
          @loop_running = keep_local(:loop_running) if loops_ending_passes.any?
        end

        # The block, which makes the routine +name+ and the parts cut off it, with each of the numbers
        # it keeps for one call of it recorded (#record_call_number) when a frame boundary can call it
        # again while a call of it is going (LoweringPlan#routines_reentered_at_frame_boundary).
        def with_call_numbers_recorded_for(name)
          @recording_call_numbers = @plan.routines_reentered_at_frame_boundary.include?(name)
          yield
        ensure
          @recording_call_numbers = false
        end

        # The routine's own number +name+, asked for as +what+ (keep_local), among #call_numbers when it
        # is one of CALL_NUMBERS of a routine being recorded. A lowering's keep_local calls this for each
        # number it keeps for real, and not for one kept only to be measured.
        def record_call_number(name, what)
          (@call_numbers ||= []) << name if @recording_call_numbers && CALL_NUMBERS.include?(what)
        end

        # The numbers a frame boundary's routines put back around them (#with_call_numbers_recorded_for),
        # each lowering in its own processor's instructions (its #with_call_numbers_kept). Complete once
        # every routine of the game is made.
        def call_numbers = @call_numbers || []

        # Reference#exec_repeat: the count worked out once, before the first turn; the index
        # counting 0, 1, 2... and in the game's variable from the top of each turn; and
        # +stop_when+ asked BEFORE the body, so a loop already finished on its first turn runs the
        # body no times.
        #
        # A count written in the program is compared as the number it is, with no variable of its
        # own to work out and read back each time round.
        #
        # THE TEST IS AT THE END OF A TURN: one more, compare, and a jump back while there are turns
        # left. A test at the top spends a jump out of the loop that is not taken and a jump back
        # besides, every turn. A test at the end cannot see a loop with no turns, so a count of
        # nought or less is caught before the first: none is written for a count known to be one,
        # and no test for a count known to be more.
        #
        # THE GAME'S VARIABLE IS THE COUNT where only the loop writes it (LoopForm#counts_in_index?),
        # so no turn copies a count of the loop's own into it. A loop that runs out has then counted
        # one past its last turn, and the variable is taken back by one, to the last turn's number,
        # which is what the interpreter's holds.
        def emit_repeat(node)
          known = folded(node.count)
          return if known && known <= 0

          in_index = loop_form.counts_in_index?(node)
          counter = in_index ? node.index : keep_local(:index)
          limit = known ? Build.int(known) : Build.var_ref(keep_local(:count))
          top = fresh_label("repeat")
          done = fresh_label("end_repeat")
          none = known ? nil : fresh_label("no_turns")
          unless known
            emit_value(node.count)
            emit_store(limit.name)
            jump_unless(Build.binop(:>, limit, Build.int(0)), none)
          end
          with_counter_held(node, counter) do
            emit_store_zero(counter)
            place_label(top)
            emit_copy_variable(counter, node.index) if node.index && !in_index
            jump_if(node.stop_when, done)
            with_index_below(in_index && known ? counter : nil, known) do
              children_of(node).first.each { |child| statement(child) }
            end
            emit_increment(counter)
            jump_if(Build.binop(:<, Build.var_ref(counter), limit), top)
            statement(Build.sub(counter, Build.int(1))) if in_index
            place_label(done)
          end
          place_label(none) if none
        end

        # The loop +node+ written by the block, from its count +counter+ set to nought to the label
        # every way out of it comes to. A lowering whose processor counts faster in a register than
        # in memory writes this its own way (OWN_WAYS): it may keep +counter+ in a register while
        # the block runs, where nothing the block writes can overwrite it, and put it back in its
        # variable after. A loop that makes no turns does not come this way.
        def with_counter_held(_node, _counter) = yield

        # WHAT A LOOP'S VARIABLE IS KNOWN TO BE BELOW while the loop's own statements are written: a
        # loop that counts in its variable to a count written in the program holds 0 to one less
        # than the count there, through every statement of its body, since nothing else writes it.
        # So a lowering reading a table or a list at that variable can tell, while building, that
        # the place is inside it, and leave out the test it would make as the game runs. A
        # statement cut off into a routine of its own (RoutineCuts) is written outside the loop,
        # and is told nothing.
        #
        # The count +name+ is below, or nil where nothing is known of it.
        def index_below(name) = (@indexes_below ||= {})[name]

        def with_index_below(name, count)
          return yield unless name

          (@indexes_below ||= {})[name] = count
          begin
            yield
          ensure
            @indexes_below.delete(name)
          end
        end

        # A beat (`every`, `after`) is the plain statements IR::Frames turns it into.
        def emit_beat(node) = Frames.beat_statements(node).each { |child| statement(child) }

        # Reference#exec_case: the variable read ONCE, before the first clause. A scene's usual last
        # act is to set it to the next scene, and reading it again per clause would run that one
        # too, in the same pass.
        def emit_case(node)
          state = keep_local(:state)
          emit_value(node.var)
          emit_store(state)
          node.clauses.each do |number, target|
            skip = fresh_label("next_clause")
            jump_unless(Build.binop(:==, Build.var_ref(state), Build.int(number)), skip)
            emit_scene(target)
            place_label(skip)
          end
        end
      end
    end
  end
end
