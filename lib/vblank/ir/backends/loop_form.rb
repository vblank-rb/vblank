# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # Which shape a `repeat` is lowered to on a cartridge, decided from the program alone, for
      # every console whose loops Backends::ControlFlow writes.
      #
      # A loop keeps a count of the turns it has made. The interpreter keeps that count to itself
      # and hands it to the game's variable at the top of each turn (Reference#exec_repeat), so a
      # body that wrote the variable would not change how many turns are made. Kept that way on a
      # console, every turn copies the count into the variable: a load and a store that most loops
      # have no use for, since nothing but the loop ever writes its variable.
      #
      # So the question asked here is whether the game's variable can BE the count. It can when
      # the loop is the only statement in the whole program that names it as anything but a number
      # to read: then it holds the turn's number through every turn, as the interpreter's does,
      # and the loop counts in it.
      #
      # The Advance asks more, in GBA::LoopForm, which is still its own: whether the count can stay
      # in two registers, whether one statement that would overwrite them can be bracketed, and
      # whether a loop whose index nothing reads can count down. Those answers rest on which
      # registers each kind of statement leaves alone, which is each processor's to say. Sharing
      # them needs each lowering to name the kinds that overwrite its loop registers, the way
      # GBA::LoopForm's three lists do, and a count kept in a register put back in the variable
      # wherever a pass can end, since every variable is compared with the interpreter's then.
      #
      # Nor when a second call of its routine can come while the loop is part way through
      # (LoweringPlan#routines_reentered_at_frame_boundary): the second call's turns write the variable,
      # and the interpreter's loop goes on from its own count, so the count is kept apart and put back.
      #
      # A counted while. A game's `while i < n` with `i += 1` as the last line of its body is a
      # repeat with no count of its own (the most turns there are, Guardrails::LoopNeverWaits) that
      # stops when `i < n` no longer holds. Written as it reads, every turn counts its hidden index,
      # reads `i` from memory to ask whether to stop, and adds one to `i` in memory: three times the
      # turn of a repeat on the Genesis. Where nothing but that last line writes `i` while the loop
      # runs, `i` is the loop's count, and the loop is lowered as a counted one (#counted_while,
      # ControlFlow#emit_counted_while).
      class LoopForm
        # A `while` lowered as a counted loop: the game's +variable+ counting up by one to +limit+, a
        # number written in the program or a variable nothing in the loop writes, from +starts_at+,
        # the number written into it by the statement just before the loop, or nil where that is not
        # known. +step+ is the body's last statement, the one more.
        CountedWhile = Data.define(:variable, :limit, :starts_at, :step)

        # The most turns a `while` makes (Builder#open_repeat, from PlainRuby): the biggest number.
        WHILE_TURNS = 0x7FFF_FFFF

        # The kinds that can do anything to a variable or stop the game part way through a turn:
        # the game's own instructions, and a halt, past which the loop's numbers are compared as
        # they were left.
        UNCOUNTED_KINDS = %i[raw halt].freeze

        # +apart_in+: the routines whose loops keep their counts apart from the game's variables.
        # +waits+, given a list of statements, answers whether they can reach a frame boundary
        # (LoweringPlan#statements_wait?); without it, any call is taken as one that can.
        def initialize(program, apart_in: [], &waits)
          @program = program
          @waits = waits || ->(statements) { statements.any? { |node| %i[wait_vblank loop call call_one_of case].include?(node.kind) } }
          @statements_naming = Hash.new(0)
          @before = {}.compare_by_identity
          program.walk do |node|
            [node.children, (node.else&.children if node.kind == :if)].compact.each do |list|
              list.each_cons(2) { |earlier, later| @before[later] = earlier }
            end
            next if node.kind == :var_ref

            Reach::VARIABLES_OF[node.kind]&.call(node)&.each { |name| @statements_naming[name] += 1 }
          end
          @kept_apart = Set.new.compare_by_identity
          Reach.statements_from(*apart_in).each { |node| @kept_apart << node if node.kind == :repeat }
          @counted_whiles = {}.compare_by_identity
        end

        # Whether +node+, a repeat, can count its turns in the game's own variable: it has one, no
        # other statement names it (Reach::VARIABLES_OF) but to read it, and its routine is not called
        # again while it is part way through.
        def counts_in_index?(node) = !node.index.nil? && @statements_naming[node.index] == 1 && !@kept_apart.include?(node)

        # The CountedWhile +node+ is, or nil. It is one where:
        #
        # - it is a `while`: a repeat of WHILE_TURNS turns whose index only it names, stopping when
        #   `variable < limit` no longer holds;
        # - the last statement of its body adds one to +variable+, and no other statement the body
        #   runs, in it or in a routine it calls, names +variable+ (or +limit+, where that is a
        #   variable) but to read it, so the variable moves only by that one more;
        # - nothing in the body can reach a frame boundary or stop the game: the checked run compares
        #   every variable as a pass ends, the loop's hidden index among them, and a counted while
        #   keeps that index only as it ends (it is the turns made, the variable less where it
        #   started).
        #
        # A `while` whose start is not known can, in principle, run more turns than WHILE_TURNS
        # (from below -2**31 + n up to n) where the interpreter stops it; that is more than two
        # thousand million turns with no frame boundary, which no game makes.
        def counted_while(node)
          return @counted_whiles[node] if @counted_whiles.key?(node)

          @counted_whiles[node] = find_counted_while(node)
        end

        private

        def find_counted_while(node)
          return unless node.kind == :repeat && node.count.kind == :int && node.count.value == WHILE_TURNS && counts_in_index?(node)

          variable, limit = below_test(node.stop_when)
          step = node.children.last
          return unless variable && step&.kind == :add && step.var == variable && step.operand.kind == :int && step.operand.value == 1

          moving = [variable, (limit.name if limit.kind == :var_ref)].compact
          run = Reach.statements_from(*node.children)
          called = Reach.routines_called_from(@program, node.children)
          run += Reach.statements_from(*@program.walk.select { |each| each.kind == :func && called.include?(each.name) })
          return if run.any? { |each| UNCOUNTED_KINDS.include?(each.kind) } || @waits.call(run)
          return if run.any? { |each| !each.equal?(step) && names_any?(each, moving) }

          CountedWhile.new(variable:, limit:, starts_at: start_of(node, variable), step:)
        end

        # [the variable, the limit] of a stop test `(variable < limit) == 0` (how PlainRuby writes
        # `while variable < limit`) or `variable >= limit`; the limit a number written in the program
        # or another variable. Nil for any other test.
        def below_test(test)
          return unless test.kind == :binop

          below =
            if test.op == :== && test.rhs.kind == :int && test.rhs.value.zero? && test.lhs.kind == :binop && test.lhs.op == :<
              test.lhs
            elsif test.op == :>=
              test
            end
          return unless below && below.lhs.kind == :var_ref && %i[int var_ref].include?(below.rhs.kind)
          return if below.rhs.kind == :var_ref && below.rhs.name == below.lhs.name

          [below.lhs.name, below.rhs]
        end

        # Whether +node+ names any of +names+ but by reading it in a value.
        def names_any?(node, names)
          return false if node.kind == :var_ref

          written = Reach::VARIABLES_OF[node.kind]&.call(node) || []
          (written + node.operand_nodes.grep(Symbol)).intersect?(names)
        end

        # The number the statement just before +node+ sets +variable+ to, or nil.
        def start_of(node, variable)
          before = @before[node]
          return unless before&.kind == :set && before.var == variable && before.value.kind == :int

          before.value.value
        end
      end
    end
  end
end
