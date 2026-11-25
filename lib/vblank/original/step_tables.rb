# frozen_string_literal: true

module VBlank
  module Original
    # The steps of an unpacking routine, kept as rows of tables where they can be. Each step a
    # routine asks for (`copy.unpack_<format>`, `copy.copy_bytes`) is the same few statements: the
    # kit's variables set to what the step is given, a call of the format's routine, and a wait for
    # the next frame (CopyReader#emit_block_call). A port asks for them from a Ruby loop over its
    # data, so written out one after another they are thousands of copies of those statements that
    # differ only in their numbers, on every build of the routine.
    #
    # So the steps are written out as they are asked for, as always, and once a stretch of the
    # routine is built (#fold_into_tables!) each run of FEWEST_ROWS or more steps that follow one
    # another, call the same routine and set the same variables to numbers written in the program,
    # becomes one loop: a table for each variable whose number differs from step to step, and on
    # each round the variables set from that round's row, the routine called and the frame waited
    # for. The same steps in the same order, with the same waits.
    #
    # A table for each variable, not one wide table of rows: a read needs no multiply to find its
    # row, a variable whose number is the same in every step is set to that number and needs no
    # table, and each table takes the narrowest width its numbers fit, where a slot's number or a
    # format's needs a byte and a place in the copy a word.
    #
    # What ends a run: a step given a value the routine works out as it runs (a place read from the
    # copy) is left as it is, and so is anything else the routine does between two steps. Each step
    # records where its statements are in the container they went into, and a step joins a run only
    # when its statements start right after the run's last. A run whose statements have moved since
    # is left as written, which is the routine as it was built.
    class StepTables
      # The fewest steps in a run made into a loop. With fewer, the loop and its reads of the
      # tables cost about what the steps written out do.
      FEWEST_ROWS = 3

      # One step: the indexes of its first and last statements in its container, those statements,
      # and the number each variable was set to.
      Step = Data.define(:first_at, :last_at, :first, :last, :row)

      # Steps that follow one another in +container+, each setting +variables+ and calling +routine+.
      class Run
        attr_reader :container, :routine, :variables, :steps

        def initialize(container, routine, variables, step)
          @container = container
          @routine = routine
          @variables = variables
          @steps = [step]
        end

        def first_at = @steps.first.first_at
        def last_at = @steps.last.last_at

        # Whether +step+, recorded in +container+, setting +variables+ and calling +routine+, comes
        # straight after this run's last step.
        def continued_by?(container, routine, variables, step)
          container.equal?(@container) && routine == @routine && variable_names(variables) == variable_names(@variables) &&
            step.first_at == last_at + 1 && step_in_place?(@steps.last)
        end

        # Whether every step's statements are still where they were recorded.
        def in_place? = @steps.all? { |step| step_in_place?(step) }

        private

        def step_in_place?(step) = @container.children[step.first_at].equal?(step.first) && @container.children[step.last_at].equal?(step.last)

        def variable_names(variables) = variables.map(&:name)
      end

      # +internals+ (a Packing::BlockKitInternals) writes the wait after each step.
      def initialize(builder, internals)
        @builder = builder
        @internals = internals
        @runs = []
        @tables_made = 0
      end

      # One step: each [variable, value] of +stores+ set in order, +routine+ called, and the wait for
      # the next frame.
      def emit_step(routine, stores)
        container = @builder.statement_mark.container
        first_at = container.children.length
        stores.each { |variable, value| variable.store!(value) }
        @builder.call(routine)
        @internals.emit_wait
        record_step(container, first_at, routine, stores)
      end

      # Every run of steps recorded so far made into a table loop, where it has FEWEST_ROWS or more.
      # Runs are folded last first, so a fold leaves the indexes of the runs before it in its
      # container as they were.
      def fold_into_tables!
        runs = @runs
        @runs = []
        runs.reverse_each do |run|
          next unless run.steps.length >= FEWEST_ROWS && run.in_place?

          run.container.children[run.first_at..run.last_at] = table_loop_statements(run)
        end
      end

      private

      def record_step(container, first_at, routine, stores)
        values = stores.map(&:last)
        last_at = container.children.length - 1
        return unless values.all?(Integer) && last_at >= first_at

        variables = stores.map(&:first)
        step = Step.new(first_at: first_at, last_at: last_at, first: container.children[first_at],
                        last: container.children[last_at], row: values)
        run = @runs.last
        if run&.continued_by?(container, routine, variables, step)
          run.steps << step
        else
          @runs << Run.new(container, routine, variables, step)
        end
      end

      # The tables of +run+ and its loop, built where the builder records now and taken back from
      # there, to be put in place of the run's steps.
      def table_loop_statements(run)
        mark = @builder.statement_mark
        columns = run.variables.each_index.map { |column| table_column(run.steps.map { |step| step.row[column] }) }
        @builder.repeat(run.steps.length) do |row|
          run.variables.zip(columns) { |variable, column| variable.store!(column.is_a?(Integer) ? column : column[row]) }
          @builder.call(run.routine)
          @internals.emit_wait
        end
        @builder.take_statements_since(mark)
      end

      # The number every step set a variable to, or a table of them, a row for each step.
      def table_column(values)
        return values.first if values.uniq.one?

        width, signed = table_width(values)
        name = Messages::MadeNames.make(:unpacking_part, part: :"step_table_#{@tables_made += 1}")
        # Must be one of the build's unique names: the count runs on over the whole routine, so a
        # part built alone numbers its tables from 1 where the whole routine numbered them after the
        # parts before it. The comparison of the two builds evens out unique names by the order they
        # are first used (PartPrograms#refuse_part_built_apart!), as it does a `repeat`'s index.
        @builder.unique_names << name
        @builder.table(name, values, width: width, signed: signed)
      end

      def table_width(values)
        low, high = values.minmax
        return [:byte, false] if low >= 0 && high <= 0xFF
        return [:half, false] if low >= 0 && high <= 0xFFFF
        return [:half, true] if low >= -0x8000 && high <= 0x7FFF

        [:word, low.negative?]
      end
    end
  end
end
