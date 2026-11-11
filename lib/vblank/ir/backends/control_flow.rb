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
      #   emit_scene(scene)               a scene's routine run, with what its arrival owes
      #
      # What a statement means is Reference's (#exec_if, #exec_repeat, #exec_case), and each console's
      # checked run holds its cartridge to that after every pass. The kinds a console draws and plays
      # with stay in its own lowering.
      module ControlFlow
        # The statements written here (Lowering#statements_written_by), each by its own method.
        STATEMENT_KINDS = %i[if loop repeat every after case].freeze

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

        # Reference#exec_repeat: the count worked out once, before the first pass; the index
        # counting 0, 1, 2... and stored in the game's variable at the top of each pass; and
        # +stop_when+ asked BEFORE the body, so a loop already finished on its first pass runs the
        # body no times.
        #
        # A count written in the program is compared as the number it is, with no variable of its
        # own to work out and read back each time round.
        def emit_repeat(node)
          index = keep_local(:index)
          known = folded(node.count)
          limit = known ? Build.int(known) : Build.var_ref(keep_local(:count))
          unless known
            emit_value(node.count)
            emit_store(limit.name)
          end
          emit_store_zero(index)
          top = fresh_label("repeat")
          done = fresh_label("end_repeat")
          place_label(top)
          jump_unless(Build.binop(:<, Build.var_ref(index), limit), done)
          emit_copy_variable(index, node.index) if node.index
          jump_if(node.stop_when, done)
          children_of(node).first.each { |child| statement(child) }
          emit_increment(index)
          jump(top)
          place_label(done)
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
