# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # Turns the statement tree the lowering builds into Ruby: the body of the game's class.
        # The only place in the backend that writes Ruby.
        #
        # The tree has no operators in it: every number a game keeps goes through a runtime
        # function (runtime/rg_int32.rb). What the printer has to know:
        #
        # - A CONDITION IS A NUMBER, nought or not. In Ruby only nil and false are false, so a
        #   number taken as a condition is written as a comparison with nought (`while x != 0`),
        #   never bare, which would always be taken. A comparison taken as one is Ruby's own
        #   comparison (`if a < b`), which is true or false already.
        # - THE GAME'S OWN ARITHMETIC IS WRITTEN AS RUBY'S OPERATORS (INLINE_OPERATORS,
        #   WRAPPED_OPERATORS), each in parentheses, so no precedence is needed. It runs every
        #   frame, and YJIT compiles an operator on small numbers to a few instructions but a
        #   runtime method only as a call: a `+` through rg_add was two calls. A sum, difference or
        #   product that can pass 32 bits keeps its answer in a temporary of its own and calls
        #   rg_i32 to come round only when it has, which a game's numbers nearly never do. A shift
        #   by a count written in the program is an operator too (SHIFTS). The operands are worked
        #   out left to right, as the call worked them out.
        # - A LIST ITEM IS READ IN ONE STEP (#list_item_call): the list's own method, or for a list
        #   that is always full its Array's own `[]`, never the runtime's chain of small calls.
        # - A RESUMABLE ROUTINE PICKS ITS STEP BY HALVING (#print_step_choice), not by a `case`.
        # - WHERE A NAME LIVES. Everything the game keeps — its variables, lists, tables, the
        #   arrays of routines it calls by number, the art the runtime reads — is an instance
        #   variable of the game, set in rg_game_setup; a routine's own locals are Ruby locals. The
        #   printer writes each as an instance variable, and the build moves every one of them into
        #   a holder object of no more than Ruby keeps at fixed places (FieldHolders).
        # - A ROUTINE IS A METHOD, called by name, and one picked from an array by number is that
        #   array's block calling it by name.
        # - A LONG ROUTINE IS SEVERAL METHODS. Ruby's compiler walks a method's branches by
        #   recursion on the machine's stack, one level for each `if`, `while` or `? :` in the whole
        #   method, so the stack a method needs grows with its length. A thread other than the main
        #   one, and so a Ractor, has a small stack: there a method of about 29,000 plain branches,
        #   or 9,000 sums with their check for coming round, is too long to compile, and Ruby stops
        #   with "stack level too deep" before the game's first line runs (the main thread's stack
        #   holds about seven times that). A data pack's unpacking is long, and is played in a
        #   Ractor (Live::BackgroundUnpacking). So a routine of more than MOST_BRANCHES_A_METHOD is
        #   printed in parts (#print_part_call), each a method of its own, and no method is longer
        #   than that whatever the routine's length. A routine shorter than that is printed whole,
        #   as before, since a call costs a little each time.
        # - MANY LOCALS STOP RUBY ITSELF. On an arm64 machine YJIT panics, and Ruby dies ("YJIT has
        #   panicked", in yjit::asm::arm64::add), the first time it compiles a method of more than
        #   about 490 locals: an add whose number does not fit the instruction, which holds up to
        #   4095, and 8 bytes a local is about that many. Every sum a routine checks for coming
        #   round keeps its answer in a local (w_1, w_2...), so a long unrolled routine (a data
        #   pack's unpacking) reached that in one method, parts included. Two things keep every
        #   method well under MOST_LOCALS_A_METHOD: a temporary is read only inside its own `? :`,
        #   so the names are used again after MOST_TEMPORARIES_A_METHOD of them, and a routine whose
        #   own locals would pass the limit keeps them as instance variables, as a routine in parts
        #   does. A method printed with more all the same stops the build (#refuse_too_many_locals!)
        #   rather than Ruby.
        class Printer
          Statements = Computer::Statements
          # What the printer raises for something it cannot write: the computer builds' error, a
          # BuildError. Named here, since nothing around the printer names it.
          LoweringError = Computer::LoweringError
          INDENT = "  "

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # Runtime functions of two numbers written as Ruby's operator: a comparison, 1 or 0 as a
          # number and true or false as a condition, and the bits, which cannot pass 32 bits.
          COMPARISONS = Ractor.make_shareable({ "rg_lt" => "<", "rg_le" => "<=", "rg_gt" => ">", "rg_ge" => ">=",
                                                "rg_eq" => "==", "rg_ne" => "!=" })
          INLINE_OPERATORS = Ractor.make_shareable({ "rg_and" => "&", "rg_or" => "|", "rg_xor" => "^" })
          # Each comparison of a number with a name, as the comparison of the name with the number
          # (#narrow_by_test).
          FLIPPED_COMPARISONS = Ractor.make_shareable({ "rg_lt" => "rg_gt", "rg_le" => "rg_ge", "rg_gt" => "rg_lt",
                                                        "rg_ge" => "rg_le", "rg_eq" => "rg_eq", "rg_ne" => "rg_ne" })
          # ...and the ones that can pass 32 bits, and so come round (rg_i32) when they do.
          WRAPPED_OPERATORS = Ractor.make_shareable({ "rg_add" => "+", "rg_sub" => "-", "rg_mul" => "*" })
          OPERATORS_OF_TWO = Ractor.make_shareable(Set.new(COMPARISONS.keys + INLINE_OPERATORS.keys + WRAPPED_OPERATORS.keys))

          # The runtime functions that test two conditions, written as Ruby's own test of two
          # comparisons (#boolean): the operator that leaves its right side unworked when the left
          # decides, and the one that works out both. The interpreter works out both sides
          # always, so the first is used only where the right side cannot stop the game or change
          # anything (#pure?).
          BOOLEANS = Ractor.make_shareable({ "rg_both" => ["&&", "&"], "rg_either" => ["||", "|"] })

          # The most steps of a resumable routine tested for one after another, once halving has
          # narrowed the counter down to them (#print_step_choice).
          STEPS_TESTED_IN_TURN = 4

          # The most steps written in place of their goto one inside another (#step_written_in_place?),
          # and the most statements and branches such a step holds: the steps that count a loop on
          # and test it are a few lines.
          MOST_STEPS_IN_PLACE = 4
          MOST_STATEMENTS_IN_PLACE = 8
          MOST_BRANCHES_IN_PLACE = 12

          # The shifts, written as Ruby's operator when their count is written in the program
          # (#written_shift_count?).
          SHIFTS = Ractor.make_shareable({ "rg_shl" => "<<", "rg_shr" => ">>" })

          # The runtime functions that read or write one item of a list, written as the list's own
          # method (#list_item_call), by the method's name.
          LIST_ITEM_METHODS = Ractor.make_shareable({ "rg_list_get" => "get", "rg_list_set" => "set" })

          # The runtime functions that change how many items a list holds, or where its first is
          # (#always_full_lists).
          LIST_RESIZING = Ractor.make_shareable(Set["rg_list_empty", "rg_list_push", "rg_list_drop", "rg_list_copy"])

          # How each C type a table is kept in packs its numbers into bytes, for a big table
          # written as base64: little-endian, the width the type holds.
          PACKING = Ractor.make_shareable({ "int8_t" => "c*", "uint8_t" => "C*", "char" => "C*",
                                            "int16_t" => "s<*", "uint16_t" => "S<*", "int32_t" => "l<*" })

          # The runtime's tables that grow with a game's art and sound, kept as binary Strings
          # rather than Arrays where the game never writes them (see "THE GAME'S ART AND SOUND" in
          # runtime/rg_runtime.rb): a full collection reads every slot of an Array, and these are
          # millions. The runtime reads each only by one index at a time (or through the methods
          # its classes add), which a String of that class answers as an Array does. A game's own
          # tables stay Arrays: the runtime's routines that are handed one read it as an Array.
          KEPT_AS_BYTES = Ractor.make_shareable(Set["rg_game_image_pixels", "rg_game_tile_pixels", "rg_game_map_cells",
                                                    "rg_game_music", "rg_game_recording_samples"])

          # The tables of KEPT_AS_BYTES kept so, unfrozen, where the game writes them: the map cells,
          # which the start file writes for a background read from it, and which the screen reads
          # through their class (RgHalves#entries).
          WRITTEN_AS_BYTES = Ractor.make_shareable(Set["rg_game_map_cells"])

          # The runtime's class for a table of KEPT_AS_BYTES, by the C type it is kept in.
          BYTES_CLASS = Ractor.make_shareable({ "int8_t" => "RgSignedBytes", "uint8_t" => "RgBytes", "int16_t" => "RgSignedHalves",
                                                "uint16_t" => "RgHalves", "int32_t" => "RgWords" })

          # The most branches one printed method holds (#branches_in counts them), well inside what
          # a Ractor's stack compiles (see the class's heading).
          MOST_BRANCHES_A_METHOD = 3_000

          # The most locals one printed method has, well inside what YJIT compiles (see "MANY
          # LOCALS" in the class's heading). A routine whose locals would pass it keeps them as
          # instance variables (#print_function), as a routine printed in parts does.
          MOST_LOCALS_A_METHOD = 400

          # The most temporaries one printed method names (#operator_of_two): past it, the names
          # are used again from the first.
          MOST_TEMPORARIES_A_METHOD = 256

          # What a part of a routine hands back to the method that called it, besides nil (it ran
          # to its end, so the caller goes on) and the routine's own 0 or 1 (the routine hands that
          # back at once): that the routine goes on to its next step, leaves its loop, or returns.
          PART_ENDINGS = Ractor.make_shareable({ goto: ":rg_next", break: ":rg_break", return: ":rg_return" })

          # The statements that always leave the method they are printed in, so a part ending in one
          # needs no nil after it.
          LEAVING_STATEMENTS = [Statements::Goto, Statements::Pause, Statements::Finish, Statements::Return].freeze

          # Every function the printed code calls by name, so the build can say which of them the
          # runtime does not have (Lowering#runtime_gaps).
          attr_reader :called

          def initialize
            @out = +""
            @setup = []
            @called = Set.new
            @branches = {}.compare_by_identity
          end

          # The body of the game's class: rg_game_setup, which gives every instance variable its
          # starting value, and then a method for every routine. +items+ is the top level.
          def print_file(items)
            @lists = items.grep(Statements::ListStorage).to_set { |list| list.name.text }
            @always_full = always_full_lists(items)
            @routine_names = items.grep(Statements::Function).to_set { |function| function.name.text }
            routines = +""
            @out = routines
            items.each { |item| print_top(item) }
            @out = +""
            line(0, "def rg_game_setup")
            @setup.each { |text| @out << text }
            line(0, "end")
            line(0, "")
            @out << routines
          end

          private

          # --- the top level ---

          def print_top(item)
            case item
            when Statements::Include, Statements::Define, Statements::Prototype then nil # a method is found wherever it is defined
            when Statements::Global then add_starting_value("@#{item.name.text} = #{integer(item.value)}")
            when Statements::ConstArray then print_const_array(item)
            when Statements::StartFileArray then print_start_file_array(item)
            when Statements::Function then print_function(item)
            when Statements::FunctionTable then print_routine_table(item)
            when Statements::ListStorage then print_list_storage(item)
            when Statements::Comment then nil # the tree's own heading; the file has Ruby::WRITTEN_BY
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          def add_starting_value(text) = @setup << "#{INDENT}#{text}\n"

          # A list, made as the game starts. One that is always full (#always_full_lists) is an
          # RgFullList, or of bytes the RgByteList every list of bytes is, and the game keeps its
          # Array or String too, under a name of its own (#items_name).
          def print_list_storage(item)
            name = item.name.text
            made = "#{integer(item.capacity)}, #{integer(item.width)}, #{string(item.label)}"
            return add_starting_value("@#{name} = RgList.build(#{made})") unless @always_full.include?(name)

            add_starting_value("@#{name} = #{item.width == 1 ? 'RgList.build' : 'RgFullList.new'}(#{made})")
            add_starting_value("#{items_name(name)} = @#{name}.items")
          end

          # The instance variable an always-full list's Array is kept in: no name the lowering gives
          # a variable starts as the runtime's do.
          def items_name(list) = "@rg_items_#{list}"

          # THE LISTS THAT ARE ALWAYS FULL (runtime/rg_list.rb's RgFullList, or for a list of bytes
          # its RgByteList), each with the bytes its slot takes: lists that every declaration fills
          # (rg_list_full), and nothing empties, pushes onto, drops from or copies into. The runtime
          # changes a list's length only through those calls (and a state read in, which puts back
          # what the game had), so such a list holds its whole capacity from its declaration on, its
          # first item in its first slot. A data pack's unpacking writes its whole pack into one such
          # list of bytes.
          def always_full_lists(items)
            resized = Set.new
            items.grep(Statements::Function).each do |function|
              each_statement(function.body) do |statement|
                next unless statement.is_a?(Statements::Eval) && LIST_RESIZING.include?(statement.call.function.text)

                resized << statement.call.args.first.name.text
              end
            end
            items.grep(Statements::ListStorage).filter_map do |list|
              [list.name.text, list.width] unless resized.include?(list.name.text)
            end.to_h
          end

          # A table of routines picked by number (`call [:a, :b], number: n`): a block for each that
          # calls it by name, made in rg_game_setup so each calls the game's own (#call).
          def print_routine_table(item)
            calls = item.functions.map { |name| "-> { #{name.text} }" }
            add_starting_value("@#{item.name.text} = [#{calls.join(', ')}].freeze")
          end

          def print_function(item)
            @locals = Set.new
            @temporaries = 0
            @ranges = {}
            @routine = item.name.text
            @in_parts = list_branches(item.body) > MOST_BRANCHES_A_METHOD
            # What the steps written in place of a goto may add (#step_written_in_place?): no more
            # than keeps the method inside MOST_BRANCHES_A_METHOD.
            @branches_to_spare = MOST_BRANCHES_A_METHOD - list_branches(item.body)
            @locals_in_instance_variables = @in_parts || whole_method_local_count(item.body) > MOST_LOCALS_A_METHOD
            @parts = []
            @part_count = 0
            print_method(item.name.text, item.body, part: false)
            print_method(*@parts.shift, part: true) until @parts.empty?
          end

          # One method: the routine itself, or a +part+ of it (#print_part_call), which hands back
          # nil when it runs to its end (a step's part never does: a step ends by leaving).
          #
          # A routine printed in parts hands back nil at its end, where printed whole it hands back
          # the value of its last line, and that is left so: nothing reads it. A routine gives
          # nothing back (Statements::Function) but a resumable one, whose 1 or 0 is always handed
          # back by a `return` (Pause, Finish, or a Resume passing one on), since its steps are a
          # loop that is only ever left that way. A call whose answer is kept (Resume, RunToEnd, a
          # waiting tick handler's rg_game_timer_steps, and the runtime's rg_game_main in
          # rg_game_pass) is only ever of a resumable routine.
          def print_method(name, body, part:)
            @in_part = part
            @loops_open = 0
            @method_locals = Set.new
            line(0, "def #{name}")
            statements(1, body)
            line(1, "nil") if part && !LEAVING_STATEMENTS.include?(body.last.class)
            line(0, "end")
            line(0, "")
            refuse_too_many_locals!(name)
          end

          # +text+, a Ruby local of the method being printed, counted for #refuse_too_many_locals!.
          def method_local(text)
            @method_locals << text
            text
          end

          # The build stops, rather than Ruby when YJIT compiles the method (see MANY LOCALS in the
          # class's heading), if a method was printed with more locals than MOST_LOCALS_A_METHOD.
          def refuse_too_many_locals!(name)
            return if @method_locals.size <= MOST_LOCALS_A_METHOD

            raise LoweringError, "the routine #{@routine} was written as a Ruby method (#{name}) with " \
                                 "#{@method_locals.size} locals. YJIT can stop Ruby on a method with more than " \
                                 "#{MOST_LOCALS_A_METHOD}, so the Ruby lowering cannot write this routine yet."
          end

          # A small table is its numbers, sixteen a line. A big one is its bytes in base64, read
          # back when the game starts, which keeps a picture of thousands of pixels to a few lines.
          #
          # Every number is checked to be a 32-bit one (#integer), and a table of bytes is checked
          # as it is packed (#print_table_of_bytes) rather than here: a game's recordings can be tens
          # of millions of numbers, and turning each into a String first took seconds.
          def print_const_array(item)
            name = "@#{item.name.text}"
            frozen = item.writable ? "" : ".freeze"
            if KEPT_AS_BYTES.include?(item.name.text) && (!item.writable || WRITTEN_AS_BYTES.include?(item.name.text))
              print_table_of_bytes(item, frozen)
            elsif item.values.size > MOST_WRITTEN_AS_NUMBERS && item.all_zeros?
              # Zeros until the start file fills them (ConstArray#all_zeros?): made at that size as
              # the game starts, not read from base64 of millions of zeros.
              add_starting_value("#{name} = Array.new(#{integer(item.values.size)}, 0)#{frozen}")
            elsif item.values.size > MOST_WRITTEN_AS_NUMBERS
              refuse_numbers_past_32_bits!(item.values)
              packing = PACKING.fetch(item.type) { raise LoweringError, "the printer has no packing for C's #{item.type}" }
              bytes = [item.values.pack(packing)].pack("m0")
              add_starting_value("#{name} = #{string(bytes)}.unpack1(\"m\").unpack(#{string(packing)})#{frozen}")
            elsif item.values.empty?
              add_starting_value("#{name} = [0]#{frozen}")
            else
              values = item.values.map { |value| integer(value) }
              rows = values.each_slice(16).map { |row| "#{INDENT * 2}#{row.join(', ')},\n" }.join
              @setup << "#{INDENT}#{name} = [\n#{rows}#{INDENT}]#{frozen}\n"
            end
          end

          # A table of KEPT_AS_BYTES: its bytes in base64, held as the runtime's class for its type.
          # An empty one holds one entry, nought, as an empty table written as numbers does. One of
          # zeros alone is its size in bytes of zeros, made as the game starts. A table the start file
          # writes (the map cells of a background read from it) is left unfrozen, +frozen+ empty.
          def print_table_of_bytes(item, frozen = ".freeze")
            kept_as = BYTES_CLASS.fetch(item.type) { raise LoweringError, "the printer cannot keep C's #{item.type} as bytes" }
            packing = PACKING.fetch(item.type)
            if item.values.size > MOST_WRITTEN_AS_NUMBERS && item.all_zeros?
              bytes = item.values.size * [0].pack(packing).bytesize
              return add_starting_value("@#{item.name.text} = #{kept_as}.of(\"\\0\".b * #{integer(bytes)})#{frozen}")
            end

            refuse_numbers_past_32_bits!(item.values)
            values = item.values.empty? ? [0] : item.values
            bytes = [values.pack(PACKING.fetch(item.type))].pack("m0")
            add_starting_value("@#{item.name.text} = #{kept_as}.of(#{string(bytes)}.unpack1(\"m\"))#{frozen}")
          end

          # An array the start file fills (Statements::StartFileArray): its size alone, zeros until the runtime
          # puts the file's entries in it.
          def print_start_file_array(item)
            count = integer([item.count, 1].max)
            made = case item.type
                   when "uint8_t" then "RgBytes.new(#{count})"
                   when "int8_t" then "RgSignedBytes.new(#{count})"
                   else "Array.new(#{count}, 0)"
                   end
            add_starting_value("@#{item.name.text} = #{made}")
          end

          # --- statements ---

          # +list+ written out here, or, in a routine printed in parts when +list+ is longer than a
          # method holds, cut: its statements a run at a time into parts, and one too long for a part
          # on its own written here with what it holds in parts (#heavy?).
          def statements(depth, list)
            return list.each { |statement| statement(depth, statement) } unless @in_parts && list_branches(list) > MOST_BRANCHES_A_METHOD

            run = []
            run_branches = 0
            list.each do |statement|
              branches = branches_in(statement)
              if heavy?(statement)
                print_part_call(depth, run)
                run = []
                run_branches = 0
                statement(depth, statement)
              else
                if run_branches + branches > MOST_BRANCHES_A_METHOD
                  print_part_call(depth, run)
                  run = []
                  run_branches = 0
                end
                run << statement
                run_branches += branches
              end
            end
            print_part_call(depth, run)
          end

          # A statement longer than a method holds, in a routine printed in parts: the statements
          # inside it are each put in parts of their own (#inner_statements).
          def heavy?(statement) = @in_parts && branches_in(statement) > MOST_BRANCHES_A_METHOD

          # The statements inside +owner+ (an if's branch, a loop's body, a step).
          def inner_statements(depth, list, owner)
            heavy?(owner) ? print_part_call(depth, list) : statements(depth, list)
          end

          # +list+ as a part of the routine, a method of its own printed after it, and its call here.
          # What the part hands back is handed on (PART_ENDINGS): a part only stops the routine,
          # leaves its loop or goes to the next step through the method it was cut from.
          def print_part_call(depth, list)
            return if list.empty?

            name = "rg_part_#{@part_count += 1}_#{@routine}"
            @parts << [name, list]
            endings = endings_of(list, in_loop: false)
            return line(depth, name) if endings.empty?

            line(depth, "#{method_local('rg_part_ended')} = #{name}")
            if @in_part
              line(depth, "break if rg_part_ended == #{PART_ENDINGS[:break]}") if endings.include?(:break) && @loops_open.positive?
              line(depth, "return rg_part_ended unless rg_part_ended.nil?")
            else
              line(depth, "next if rg_part_ended == #{PART_ENDINGS[:goto]}") if endings.include?(:goto)
              line(depth, "break if rg_part_ended == #{PART_ENDINGS[:break]}") if endings.include?(:break)
              line(depth, "return if rg_part_ended == #{PART_ENDINGS[:return]}") if endings.include?(:return)
              line(depth, "return rg_part_ended unless rg_part_ended.nil?") if endings.include?(:value)
            end
          end

          # How +list+ can leave the method it is printed in: :goto, :break (of a loop outside it),
          # :return, or :value (the routine's own 0 or 1).
          def endings_of(list, in_loop:)
            list.each_with_object(Set.new) do |statement, endings|
              case statement
              when Statements::Goto then endings << :goto
              when Statements::Pause, Statements::Finish, Statements::Resume then endings << :value
              when Statements::Return then endings << :return
              when Statements::Break then endings << :break unless in_loop
              when Statements::If then endings.merge(endings_of(statement.body, in_loop: in_loop))
                                                .merge(endings_of(statement.otherwise, in_loop: in_loop))
              when Statements::Block then endings.merge(endings_of(statement.body, in_loop: in_loop))
              when Statements::While then endings.merge(endings_of(statement.body, in_loop: true))
              end
            end
          end

          # Leaving the method by +ending+ (PART_ENDINGS): from a part, handing it back; from the
          # routine itself, Ruby's own +word+.
          def leave(depth, ending, word)
            line(depth, @in_part ? "return #{PART_ENDINGS.fetch(ending)}" : word)
          end

          # --- how long a routine is ---

          # The branches +statement+ is printed with, as Ruby's compiler counts its cost: an if, a
          # loop or a comparison taken as a number (`? :`) one each, and a sum with its check for
          # coming round three, its `||` making the branch dearer (measured, see the class's heading).
          def branches_in(statement)
            @branches[statement] ||=
              case statement
              when Statements::Eval then expression_branches(statement.call)
              when Statements::Assign then expression_branches(statement.target) + expression_branches(statement.value)
              when Statements::Local then expression_branches(statement.value)
              when Statements::If
                1 + expression_branches(statement.condition) + list_branches(statement.body) + list_branches(statement.otherwise)
              when Statements::While then 1 + expression_branches(statement.condition) + list_branches(statement.body)
              when Statements::Block then list_branches(statement.body)
              when Statements::Steps then (2 * statement.steps.size) + statement.steps.sum { |step| list_branches(step) } # #print_step_choice's tests
              when Statements::Resume, Statements::RunToEnd then 1 + expression_branches(statement.call)
              else 0
              end
          end

          def list_branches(list) = list.sum { |statement| branches_in(statement) }

          # The locals a routine of +body+ would have printed whole as one method: its own, a
          # temporary for each sum checked for coming round (MOST_TEMPORARIES_A_METHOD at most), and
          # the most a RunToEnd keeps.
          def whole_method_local_count(body)
            own = Set.new
            kept = 0
            wrapped = 0
            each_statement(body) do |statement|
              own << statement.name.text if statement.is_a?(Statements::Local)
              kept = [kept, statement.counters.size + statement.locals.size].max if statement.is_a?(Statements::RunToEnd)
              wrapped += wrapped_operators_in_statement(statement)
            end
            own.size + kept + [wrapped, MOST_TEMPORARIES_A_METHOD].min
          end

          # Every statement in +list+ and in the statements it holds.
          def each_statement(list, &block)
            list.each do |statement|
              yield statement
              case statement
              when Statements::If then each_statement(statement.body, &block)
                                       each_statement(statement.otherwise, &block)
              when Statements::While, Statements::Block then each_statement(statement.body, &block)
              when Statements::Steps then statement.steps.each { |step| each_statement(step, &block) }
              end
            end
          end

          # The sums, differences and products +statement+ checks for coming round (#wrapped_operator?),
          # not counting the statements it holds.
          def wrapped_operators_in_statement(statement)
            case statement
            when Statements::Eval, Statements::Resume, Statements::RunToEnd then wrapped_operators_in(statement.call)
            when Statements::Assign then wrapped_operators_in(statement.target) + wrapped_operators_in(statement.value)
            when Statements::Local then wrapped_operators_in(statement.value)
            when Statements::If, Statements::While then wrapped_operators_in(statement.condition)
            else 0
            end
          end

          def wrapped_operators_in(item)
            case item
            when Statements::Index then wrapped_operators_in(item.array) + wrapped_operators_in(item.index)
            when Statements::Call
              own = if wrapped_operator?(item) then 1
                    elsif LIST_ITEM_METHODS.key?(item.function.text) then 2 # #list_item_in_place's index and number
                    else 0
                    end
              own + item.args.sum { |arg| wrapped_operators_in(arg) }
            else 0
            end
          end

          # Whether +call+ is printed as Ruby's own +, - or * with its check for coming round
          # (#operator_of_two), which keeps its answer in a temporary.
          def wrapped_operator?(call)
            return false unless call.args.size == 2

            function = call.function.text
            WRAPPED_OPERATORS.key?(function) || (function == "rg_shl" && written_shift_count?(call.args[1]))
          end

          def expression_branches(item)
            case item
            when Statements::Index then expression_branches(item.array) + expression_branches(item.index)
            when Statements::Call
              function = item.function.text
              own = if COMPARISONS.key?(function) || (BOOLEANS.key?(function) && boolean?(item)) then 1
                    elsif wrapped_operator?(item) || LIST_ITEM_METHODS.key?(function) then 3
                    else 0
                    end
              own + item.args.sum { |arg| expression_branches(arg) }
            else 0
            end
          end

          # --- statements ---

          def statement(depth, item)
            case item
            when Statements::Eval then line(depth, expression(item.call))
            when Statements::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)}")
            when Statements::Local then print_local(depth, item)
            when Statements::If then print_if(depth, item)
            when Statements::While then print_while(depth, item)
            when Statements::Break then @loops_open.positive? ? line(depth, "break") : leave(depth, :break, "break")
            when Statements::Return then leave(depth, :return, "return")
            when Statements::Block then print_block(depth, item)
            when Statements::Comment then comment(depth, item.text)
            when Statements::Steps then print_steps(depth, item)
            when Statements::Goto then print_goto(depth, item)
            when Statements::Pause then line(depth, "#{expression(item.counter)} = #{integer(item.step)}")
                               line(depth, "return 1")
            when Statements::Finish then line(depth, "#{expression(item.counter)} = 0")
                                line(depth, "return 0")
            when Statements::Resume then print_resume(depth, item)
            when Statements::RunToEnd then print_run_to_end(depth, item)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
          end

          # A block's statements, as they are: a Ruby method's locals are its own already. A counted
          # loop's (#counted_loop_ranges) are printed knowing its index and variable stay below its
          # count, which #range_of reads.
          def print_block(depth, item)
            with_ranges(counted_loop_ranges(item.body)) { statements(depth, item.body) }
          end

          # The block printed knowing what +known+ says of the numbers it names (#range_of), as well as
          # what was known around it; nil knows nothing more.
          def with_ranges(known)
            return yield unless known

            outside = @ranges
            @ranges = @ranges.merge(known)
            yield
          ensure
            @ranges = outside if known
          end

          # A resumable routine run from its start for an answer (Statements::RunToEnd): the counters and locals
          # it can reach kept in Ruby locals, the counters set to 0, and all put back after.
          def print_run_to_end(depth, item)
            kept = item.counters + item.locals.map(&:name)
            kept.each_with_index { |name, k| line(depth, "#{method_local("rg_kept_#{k}")} = #{expression(name)}") }
            item.counters.each { |counter| line(depth, "#{expression(counter)} = 0") }
            line(depth, "rg_wait_vblank_while_answering if #{expression(item.call)} == 1")
            kept.each_with_index { |name, k| line(depth, "#{expression(name)} = rg_kept_#{k}") }
          end

          # A resumable routine's steps (Computer::Resumable): a loop that picks the step its counter
          # names (#print_step_choice), each step going on to the next with `next`, and leaving the
          # method with 1 or 0.
          #
          # THE STEP IT IS ON IS A RUBY LOCAL, rg_step, read from the counter as the routine is called
          # and set by each goto, and the counter is written only where the routine leaves: a wait
          # (Pause) and the end (Finish) set it, and a call of a routine that waits (Resume) sets it
          # to the step the call is in before it hands back 1. Nothing reads the counter while the
          # routine runs (a state is written only between frames, when every routine has left at a
          # wait), and an instance variable written at every goto cost an unpacking's loop three
          # writes a byte.
          #
          # A routine printed in parts keeps the counter as it was, an instance variable set at every
          # goto, since a part is a method of its own and cannot set the routine's local.
          def print_steps(depth, item)
            @steps_item = @in_parts ? nil : item
            if @steps_item
              line(depth, "#{method_local('rg_step')} = #{expression(item.counter)}")
              line(depth, "while true")
            else
              line(depth, "while true")
              line(depth + 1, "#{method_local('rg_step')} = #{expression(item.counter)}")
            end
            print_step_choice(depth + 1, item, 0, item.steps.size)
            line(depth, "end")
          ensure
            @steps_item = nil
          end

          # Step +number+ of +item+, where the choice picked it. A STEP THAT COMES BACK TO ITSELF
          # (#step_comes_back?), as the body of a loop cut into steps does through the steps that
          # count it on and test it, is a loop of its own: going back to it is that loop's `next`,
          # and going to any other step leaves it, rg_step set, for the choice to pick again. A loop
          # of a few steps then turns without picking a step at all.
          def print_step(depth, item, number)
            return inner_statements(depth, item.steps[number], item) unless @steps_item

            looped = step_comes_back?(number)
            line(depth, "while true") if looped
            with_step(number, looped) { statements(depth + (looped ? 1 : 0), item.steps[number]) }
            line(depth, "end") if looped
          end

          # The block printed as step +number+, a loop of its own when +looped+.
          def with_step(number, looped)
            @step_now = number
            @step_looped = looped ? number : nil
            @steps_in_place = [number]
            yield
          ensure
            @step_now = @step_looped = @steps_in_place = nil
          end

          # A goto: the step it goes on to set and the choice made again; or, where that step is the
          # one looping (#print_step), that loop's next turn; or that step's statements written here
          # (#step_written_in_place?), which saves picking it.
          def print_goto(depth, item)
            unless @steps_item
              line(depth, "#{expression(item.counter)} = #{integer(item.step)}")
              return leave(depth, :goto, "next")
            end

            target = item.step
            return line(depth, "next") if target == @step_looped
            return print_step_in_place(depth, target) if step_written_in_place?(target, @steps_in_place, spending: true)

            line(depth, "rg_step = #{integer(target)}")
            line(depth, @step_looped ? "break" : "next")
          end

          # Step +target+'s statements where a goto to it was, printed knowing nothing the statements
          # around the goto knew (a step is entered from many places).
          def print_step_in_place(depth, target)
            outside = [@step_now, @ranges]
            @steps_in_place.push(target)
            @step_now = target
            @ranges = {}
            statements(depth, @steps_item.steps[target])
          ensure
            @steps_in_place.pop
            @step_now, @ranges = outside
          end

          # Whether a goto to +target+, from inside the steps +chain+ (the step being printed, and the
          # ones written in place inside it), is written as +target+'s statements: a small step, none
          # of the chain, the chain short enough, and, when +spending+, the branches it adds within
          # what the routine has to spare.
          def step_written_in_place?(target, chain, spending: false)
            return false if chain.include?(target) || chain.size >= MOST_STEPS_IN_PLACE

            step = @steps_item.steps[target]
            branches = list_branches(step)
            return false if branches > MOST_BRANCHES_IN_PLACE || statement_count(step) > MOST_STATEMENTS_IN_PLACE
            return true unless spending
            return false if branches > @branches_to_spare

            @branches_to_spare -= branches
            true
          end

          # Whether step +number+ goes back to itself, through the steps written in place inside it.
          def step_comes_back?(number, chain = [number])
            gotos_in(@steps_item.steps[chain.last]).any? do |target|
              target == number || (step_written_in_place?(target, chain) && step_comes_back?(number, chain + [target]))
            end
          end

          # The steps the gotos in +list+ go on to.
          def gotos_in(list)
            found = []
            each_statement(list) { |statement| found << statement.step if statement.is_a?(Statements::Goto) }
            found
          end

          def statement_count(list)
            count = 0
            each_statement(list) { count += 1 }
            count
          end

          # A call of a routine that waits, made again when this one carries on: if it hands back 1,
          # this routine does too, its counter set to the step the call is in (see THE STEP IT IS ON
          # at #print_steps).
          def print_resume(depth, item)
            return line(depth, "return 1 if #{expression(item.call)} == 1") unless @steps_item

            line(depth, "if #{expression(item.call)} == 1")
            line(depth + 1, "#{expression(@steps_item.counter)} = #{integer(@step_now)}")
            line(depth + 1, "return 1")
            line(depth, "end")
          end

          # THE STEP THE COUNTER NAMES, from +first+ up to before +past+, picked by halving: a test
          # of whether it is below the middle step, then the same again on that half, until a few
          # steps are left, each then tested for in turn. So a routine of a thousand steps picks one in
          # about ten tests.
          #
          # Not a `case` on the counter, though Ruby compiles one to a table it looks the step up
          # in. YJIT compiles that look-up for the counter it saw as it compiled, a version for each
          # of the first few, and past those it falls back to testing every `when` in order. A loop
          # cut into steps (a port's unpacking writes a byte a step and waits every few hundred) comes
          # to that look-up from steps hundreds apart, so each turn of it tested hundreds of `when`s
          # before its own.
          def print_step_choice(depth, item, first, past)
            if past - first <= STEPS_TESTED_IN_TURN
              (first...past).each do |number|
                line(depth, "#{number == first ? 'if' : 'elsif'} rg_step == #{integer(number)}")
                print_step(depth + 1, item, number)
              end
              # A counter no step has (none the game writes) ends the routine, as the C does.
              line(depth, "else")
              line(depth + 1, "#{expression(item.counter)} = 0")
              line(depth + 1, "return 0")
            else
              middle = (first + past) / 2
              line(depth, "if rg_step < #{integer(middle)}")
              print_step_choice(depth + 1, item, first, middle)
              line(depth, "else")
              print_step_choice(depth + 1, item, middle, past)
            end
            line(depth, "end")
          end

          # A local is a Ruby local, or, in a routine printed in parts, where every part reads it, or
          # one with more locals than a method holds, an instance variable (the lowering names each
          # local for its routine alone).
          def print_local(depth, item)
            @locals << method_local(item.name.text) unless @locals_in_instance_variables
            line(depth, "#{name(item.name)} = #{expression(item.value)}")
          end

          # A test of a number written in the program (a loop's `stop_when` left out is a test of
          # nought) is the branch it takes, with no test.
          def print_if(depth, item)
            if item.condition.is_a?(Statements::Int)
              return inner_statements(depth, item.condition.value.zero? ? item.otherwise : item.body, item)
            end

            line(depth, "if #{condition(item.condition)}")
            with_ranges(tested_ranges(item.condition, item.body)) { inner_statements(depth + 1, item.body, item) }
            unless item.otherwise.empty?
              line(depth, "else")
              inner_statements(depth + 1, item.otherwise, item)
            end
            line(depth, "end")
          end

          def print_while(depth, item)
            line(depth, "while #{condition(item.condition)}")
            @loops_open += 1
            inner_statements(depth + 1, item.body, item)
            @loops_open -= 1
            line(depth, "end")
          end

          # A number taken as a condition: not nought; a comparison is one already, and so is a test
          # of both or either of two (#boolean).
          def condition(item)
            operator = item.is_a?(Statements::Call) && COMPARISONS[item.function.text]
            unless operator
              return boolean?(item) ? boolean(item) : "#{expression(item)} != 0"
            end

            left, right = item.args
            "#{expression(left)} #{operator} #{expression(right)}"
          end

          # Whether +item+ is a comparison, or a test of both or either of two such (BOOLEANS), however
          # deep, and so is written as Ruby's true or false (#boolean). rg_both of two comparisons was
          # a call and two numbers made of trues and falses, on every turn of a loop that tests an
          # index before it writes a list.
          def boolean?(item)
            return false unless item.is_a?(Statements::Call) && item.args.size == 2

            function = item.function.text
            COMPARISONS.key?(function) || (BOOLEANS.key?(function) && item.args.all? { |arg| boolean?(arg) })
          end

          # +item+, one #boolean? holds of, as Ruby's true or false. Both sides are worked out, left
          # first, as the interpreter works them out, unless the right is #pure?.
          def boolean(item)
            function = item.function.text
            left, right = item.args
            if (compared = COMPARISONS[function])
              "(#{expression(left)} #{compared} #{expression(right)})"
            else
              operators = BOOLEANS.fetch(function)
              "(#{boolean(left)} #{pure?(right) ? operators[0] : operators[1]} #{boolean(right)})"
            end
          end

          # Whether working out +item+ can neither stop the game nor change anything: a number, a
          # name, or Ruby's operator (#operator_of_two?) on such. A list's item can stop the game,
          # and any call can do anything.
          def pure?(item)
            case item
            when Statements::Int, Statements::Name then true
            when Statements::Call
              (operator_of_two?(item) || BOOLEANS.key?(item.function.text)) && item.args.all? { |arg| pure?(arg) }
            else false
            end
          end

          # --- expressions ---

          def expression(item)
            case item
            when Statements::Int then integer(item.value)
            when Statements::Name then name(item)
            when Statements::AddressOf then address_of(item.name)
            when Statements::Text then string(item.value)
            when Statements::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when Statements::Call then call(item)
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          # A local is itself, a constant the runtime declares (RG_FADE_INSIDE) is itself, and
          # anything else the game keeps is an instance variable.
          def name(item)
            text = item.text
            @locals.include?(text) || text.start_with?("RG_") ? text : "@#{text}"
          end

          # A routine picked from an array by its number (rg_call_routine(table[which])) is that
          # array's block for it (#print_routine_table), called.
          def call(item)
            function = item.function.text
            return "#{expression(item.args.first)}.call" if function == "rg_call_routine"
            return list_item_call(item) if LIST_ITEM_METHODS.key?(function)
            return operator_of_two(item) if operator_of_two?(item)

            return "(#{boolean(item)} ? 1 : 0)" if BOOLEANS.key?(function) && boolean?(item)

            @called << function
            "#{function}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
          end

          # A read or write of one item of a list as the list's own method (see "A READ OR WRITE OF
          # ONE ITEM" atop runtime/rg_list.rb), which gives nil for an index the list does not have:
          # then rg_list_index_fault stops the game. The list is always an instance variable, so
          # naming it twice reads nothing else.
          #
          # A list that is always full (#always_full_lists) is read and written in place instead
          # (#list_item_in_place). Any other is not: measured on a port's unpacking, its Array read
          # after asking the list for its length and its Array ran slower than the one call.
          def list_item_call(item)
            return list_item_in_place(item) if @always_full.include?(item.args.first.name.text)

            list, *rest = item.args.map { |arg| expression(arg) }
            @called << "rg_list_index_fault"
            "(#{list}.#{LIST_ITEM_METHODS.fetch(item.function.text)}(#{rest.join(', ')}) || rg_list_index_fault(#{list}))"
          end

          # An item of an always-full list read or written as its Array's own (see RgFullList atop
          # runtime/rg_list.rb), whose length is the list's: a read past the end gives nil, and one
          # below nought is caught before the Array would count it from the end. The index, and for
          # a write the number, are worked out first, each into a temporary, as the runtime's call
          # worked them out (a list read in the number can stop the game first). A write is a run of
          # statements in parentheses, not a test of its assignments, which Ruby warns of when one
          # sets a number written in the program. Out of range, rg_list_index_fault_at stops the
          # game in the interpreter's words. An index known to be nought or more (#range_of) is not
          # tested for it.
          #
          # A list of bytes is its String's own instead (#byte_item_in_place).
          def list_item_in_place(item)
            name = item.args.first.name.text
            known = range_of(item.args[1])
            above_nought = known && known[0] >= 0
            list, index, value = item.args.map { |arg| expression(arg) }
            slots = items_name(name)
            @called << "rg_list_index_fault_at"
            at = temporary
            fault = "rg_list_index_fault_at(#{list}, #{at})"
            return byte_item_in_place(name, list, index, value, at, above_nought, fault) if @always_full.fetch(name) == 1
            return "((#{at} = #{index}; #{above_nought ? '' : "#{at} >= 0 && "}#{slots}[#{at}]) || #{fault})" unless value

            kept = temporary
            fitted = @always_full.fetch(name) == 2 ? "((#{kept} & 0xFFFF) ^ 0x8000) - 0x8000" : kept
            "(#{at} = #{index}; #{kept} = #{value}; #{above_nought ? '' : "#{at} >= 0 && "}#{at} < #{slots}.size ? " \
              "(#{slots}[#{at}] = #{fitted}) : #{fault})"
          end

          # An item of an always-full list of bytes read or written as its String's own byte (see
          # RgByteList#items atop runtime/rg_list.rb). The String holds the list's whole capacity from
          # the start, so the index is tested against the list's length, which is nought until the
          # declaration fills it, and a read is made signed as the list's own read makes it. The
          # list's #set was a call, the ring's slot worked out and the index tested again, on every
          # byte an unpacking writes.
          def byte_item_in_place(name, list, index, value, at, above_nought, fault)
            bytes = items_name(name)
            in_range = "#{above_nought ? '' : "#{at} >= 0 && "}#{at} < #{list}.length"
            unless value
              byte = temporary
              return "(#{at} = #{index}; #{in_range} ? ((#{byte} = #{bytes}.getbyte(#{at})) >= 0x80 ? #{byte} - 0x100 : #{byte}) : #{fault})"
            end

            kept = temporary
            "(#{at} = #{index}; #{kept} = #{value}; #{in_range} ? #{bytes}.setbyte(#{at}, #{kept}) : #{fault})"
          end

          # A temporary of the method being printed (see MANY LOCALS in the class's heading).
          def temporary
            kept = method_local("w_#{(@temporaries % MOST_TEMPORARIES_A_METHOD) + 1}")
            @temporaries += 1
            kept
          end

          # Whether +call+ is printed as Ruby's operator (#operator_of_two): one of OPERATORS_OF_TWO, or
          # a shift by a count written in the program (#written_shift_count?).
          def operator_of_two?(call)
            return false unless call.args.size == 2

            function = call.function.text
            OPERATORS_OF_TWO.include?(function) || (SHIFTS.key?(function) && written_shift_count?(call.args[1]))
          end

          # A count of 0 to 31 written in the program, which shifts as Ruby's << and >> do. Any other
          # count empties the number (rg_shl, rg_shr), so it is left to the runtime.
          def written_shift_count?(count) = count.is_a?(Statements::Int) && count.value.between?(0, 31)

          # A runtime function of two numbers written as Ruby's operator (see the class's heading). A
          # shift right never leaves the range; a shift left can, and comes round as a sum does.
          def operator_of_two(item)
            function = item.function.text
            left, right = item.args.map { |arg| expression(arg) }
            if (compared = COMPARISONS[function])
              "(#{left} #{compared} #{right} ? 1 : 0)"
            elsif (bits = INLINE_OPERATORS[function])
              "(#{left} #{bits} #{right})"
            elsif function == "rg_shr"
              "(#{left} >> #{right})"
            elsif range_of(item)
              # Known to stay inside 32 bits (#range_of), so it needs no check for coming round.
              "(#{left} #{WRAPPED_OPERATORS[function] || SHIFTS.fetch(function)} #{right})"
            else
              @called << "rg_i32"
              kept = temporary
              operator = WRAPPED_OPERATORS[function] || SHIFTS.fetch(function)
              "((#{kept} = #{left} #{operator} #{right}) > #{Int32::MAX} || " \
                "#{kept} < #{Int32::MIN} ? rg_i32(#{kept}) : #{kept})"
            end
          end

          # THE SMALLEST AND LARGEST +item+ CAN BE, as [low, high], or nil where that is not known
          # while printing. A number written in the program is itself; a counted loop's count and
          # variable are known through its body (#counted_loop_ranges); a sum, difference, product
          # or shift of known numbers is worked out from theirs, and is known only when the whole of
          # it stays inside 32 bits, so it never comes round; a number masked by one written in the
          # program, nought or more, is at most that. So a port's `c * 2` for channel c of a loop of
          # nine is printed as Ruby's own `*`, with no check, however often it is worked out.
          def range_of(item)
            case item
            when Statements::Int then [item.value, item.value]
            when Statements::Name then @ranges[item.text]
            when Statements::Call
              return unless item.args.size == 2

              left, right = item.args
              if item.function.text == "rg_and"
                mask = [left, right].find { |arg| arg.is_a?(Statements::Int) && arg.value >= 0 }
                return mask && [0, mask.value]
              end
              return unless (a = range_of(left)) && (b = range_of(right))

              ends = case item.function.text
                     when "rg_add" then [a[0] + b[0], a[1] + b[1]]
                     when "rg_sub" then [a[0] - b[1], a[1] - b[0]]
                     when "rg_mul" then [a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1]]
                     when "rg_shl" then written_shift_count?(right) ? [a[0] << right.value, a[1] << right.value] : nil
                     when "rg_shr" then written_shift_count?(right) ? [a[0] >> right.value, a[1] >> right.value] : nil
                     end
              ends && ends.min >= Int32::MIN && ends.max <= Int32::MAX ? [ends.min, ends.max] : nil
            end
          end

          # A COUNTED LOOP, as Computer::Lowering#lower_repeat writes one, and what is known of its
          # numbers through its body: +body+ is a block's statements, its count set to a number
          # written in the program, its index to nought, then a loop while the index is below the
          # count, which hands the index to the game's variable first and adds one to it last. Inside,
          # the index and the variable are 0 to one less than the count, so long as nothing else in
          # the body sets the count, the index or the variable, and the body calls none of the game's
          # routines, which could. Nil for any other block.
          def counted_loop_ranges(body)
            return unless body.size == 3

            count, start, loop = body
            count_name, count_value = number_set(count)
            index_name, start_value = number_set(start)
            return unless loop.is_a?(Statements::While) && count_value&.positive? && start_value&.zero?

            index = Statements::Name.new(text: index_name)
            return unless loop.condition == Statements::Call.new(function: Statements::Name.new(text: "rg_lt"),
                                                                 args: [index, Statements::Name.new(text: count_name)])
            return unless loop.body.last == Statements::Assign.new(target: index,
                                                                   value: Statements::Call.new(function: Statements::Name.new(text: "rg_add"),
                                                                                               args: [index, Statements::Int.new(value: 1)]))

            first = loop.body.first
            variable = first.target.text if first.is_a?(Statements::Assign) && first.value == index && first.target.is_a?(Statements::Name)
            known = [count_name, index_name, variable].compact
            rest = loop.body[(variable ? 1 : 0)...-1]
            return if rest.empty? && variable.nil?
            return if body_sets_or_calls?(rest, known)

            [index_name, variable].compact.to_h { |name| [name, [0, count_value - 1]] }
          end

          # WHAT A TEST SAYS OF ITS NAMES, inside the branch it takes: +condition+'s comparisons of a
          # name with a number written in the program, alone or tested both together (rg_both), each
          # narrowing what was known of the name. So an unpacking's `at >= 0 && at < count`, its test
          # before a write to its list, prints the write knowing the index is nought or more. Nil
          # where the test says nothing, or +body+ sets one of the names or calls a routine of the
          # game (#body_sets_or_calls?).
          def tested_ranges(condition, body)
            known = {}
            narrow_by_test(condition, known)
            return if known.empty? || known.values.any? { |low, high| low > high } || body_sets_or_calls?(body, known.keys)

            known
          end

          # What +item+ says of the names it compares, narrowed into +known+.
          def narrow_by_test(item, known)
            return unless item.is_a?(Statements::Call) && item.args.size == 2

            function = item.function.text
            return item.args.each { |side| narrow_by_test(side, known) } if function == "rg_both"
            return unless COMPARISONS.key?(function)

            left, right = item.args
            if left.is_a?(Statements::Name) && right.is_a?(Statements::Int)
              narrow_name(known, left.text, function, right.value)
            elsif left.is_a?(Statements::Int) && right.is_a?(Statements::Name)
              narrow_name(known, right.text, FLIPPED_COMPARISONS.fetch(function), left.value)
            end
          end

          # +name+ known to stand to +number+ as +comparison+ says, narrowing what +known+ (or else
          # #range_of) knew of it.
          def narrow_name(known, name, comparison, number)
            low, high = known[name] || @ranges[name] || [Int32::MIN, Int32::MAX]
            case comparison
            when "rg_lt" then high = [high, number - 1].min
            when "rg_le" then high = [high, number].min
            when "rg_gt" then low = [low, number + 1].max
            when "rg_ge" then low = [low, number].max
            when "rg_eq" then low, high = [low, number].max, [high, number].min
            else return
            end
            known[name] = [low, high]
          end

          # The name a statement sets and the number written in the program it sets it to, or nil.
          def number_set(statement)
            case statement
            when Statements::Local then [statement.name.text, statement.value.value] if statement.value.is_a?(Statements::Int)
            when Statements::Assign
              [statement.target.text, statement.value.value] if statement.target.is_a?(Statements::Name) && statement.value.is_a?(Statements::Int)
            end
          end

          # Whether +list+ sets any of +names+, or calls a routine of the game, by name or picked from
          # an array, which can set any variable.
          def body_sets_or_calls?(list, names)
            found = false
            each_statement(list) do |statement|
              case statement
              when Statements::Assign then found ||= statement.target.is_a?(Statements::Name) && names.include?(statement.target.text)
              when Statements::Local then found ||= names.include?(statement.name.text)
              when Statements::Eval
                function = statement.call.function.text
                found ||= @routine_names.include?(function) || function == "rg_call_routine"
              when Statements::Steps, Statements::Resume, Statements::RunToEnd then found = true
              end
            end
            found
          end

          # Where a global lives, for a runtime function that reads it later. A list is an object,
          # handed over as itself; a number is not, so a variable is handed over as a lambda that
          # reads it then.
          def address_of(name)
            @lists.include?(name.text) ? "@#{name.text}" : "-> { @#{name.text} }"
          end

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # #integer's check, for a table packed as bytes, whose numbers are never written one by
          # one: the first that is not a whole number, or else the smallest or the largest when it
          # does not fit 32 bits, is refused. Asked of the whole Array at once (all?, min and max run
          # inside Ruby itself), since a block for each of millions of numbers took seconds.
          def refuse_numbers_past_32_bits!(values)
            return integer(values.find { |value| !value.is_a?(Integer) }) unless values.all?(Integer)
            return if values.empty?

            integer(values.min)
            integer(values.max)
          end

          # A Ruby string, every character outside plain ASCII escaped and nothing in it read as
          # code (String#dump escapes a # that would start an interpolation).
          def string(text) = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).dump

          def comment(depth, text) = line(depth, "# #{text.to_s.tr("\n", ' ')}")

          def line(depth, text)
            @out << (INDENT * depth) << text << "\n"
          end
        end
      end
    end
  end
end
