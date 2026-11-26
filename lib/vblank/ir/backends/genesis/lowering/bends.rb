# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # A background bent row by row (`scroll_each_row`), lowered for a Genesis. Mixed into Lowering.
          #
          # The video chip reads each plane's sideways scroll from a table in video memory, and it can
          # read one for the whole screen or one for every line: register 11's two low bits, 11 for a
          # line each (plutiedev, "Scrolling"; the Sega Genesis VDP documentation, register $0B). Line by
          # line, the table holds a long word a line, plane A's scroll and then plane B's, for all the
          # lines of the screen. That is how the console's own games ripple water and split a road: the
          # table worked out in work RAM while the game runs, and sent into video memory in the blank by
          # the chip's own copy (DMA), which moves it without the processor.
          #
          # So a game that bends turns the chip to a line each as it starts, and:
          #
          # - at each wait, before the frame's sprites and scroll go out, every bend's rows are worked out
          #   in the order every lowering works them out in (BendSchedule), each row's offset kept in a
          #   table of the bend's own, a word a row;
          # - as the wait ends the pass (Runtime::Tiles' rt_picture_prepare), each plane's lines are
          #   worked out into the line table from its scroll and the bend shown on it, if any;
          # - and the blank sends the line table where the two words of a still screen went.
          #
          # A plane shows the bend of the background up on it (Reference#bend_offset_at): the bend
          # noted as the background goes up (#emit_bend_shown), nought for one that does not bend.
          module Bends
            # The bend whose rows a wait works out, in a game whose bends are one routine
            # (LoweringPlan#bends_in_own_routine?).
            BENDS = "bends frame"

            # Reference#exec_scroll_rows: a standing declaration, gathered up front (#bends). Its rows
            # are worked out at every wait (#emit_bends), not where it is written.
            def emit_scroll_rows(_node) = nil

            # The game's bends (RowBends): the last a background is given, in the order the backgrounds
            # were first bent.
            def bends = @plan.row_bends.bends

            def bend_screen_height = Console::GENESIS.screen_height

            # Reference#work_out_bends, before the pass's wait. +painting+ is the interpreter painting a
            # game that never waits, row by row (Reference#bend_offset_at), which leaves each row variable
            # at the last row painted rather than past it.
            def emit_bends(painting: false)
              @painting_bends = painting
              emit_bends_worked_out
            ensure
              @painting_bends = false
            end

            # At a wait: the bends' rows, in place or by the routine they are kept in.
            def emit_bends_at_wait
              return if bends.empty?

              @plan.bends_in_own_routine? ? call_routine(BENDS) : emit_bends
            end

            # That routine, with the numbers of a call its steps can come inside put back around them
            # (#with_call_numbers_kept), which are known only once every routine of the game is made.
            def bend_sections
              return [] unless @plan.bends_in_own_routine?

              [routine_section(BENDS, [], routine: "the bends") { with_call_numbers_kept { emit_bends } }]
            end

            # Rows +first+ to +past+ - 1 of +bend+: its row in its variable, its steps, the row's offset
            # kept, and on to the next, leaving the variable at +past+. A single row leaves it at that row.
            # Many rows whose block allows it are worked out with the row in a register
            # (#emit_bend_rows_held).
            def emit_bend_rows(bend, first, past)
              return emit_bend_rows_held(bend, first, past) if past - first > 1 && bend_rows_held?(bend)

              top = fresh("bend_row")
              store_number(bend.row, first)
              place_label(top)
              bend.body.each { |child| statement(child) }
              emit_row_offset_kept(bend)
              return if past - first == 1

              emit_increment(bend.row)
              jump_if(Build.binop(:<, Build.var_ref(bend.row), Build.int(past)), top)
            end

            # The rows of a bend worked out as a 68000 game fills a line table: the line it is on in a
            # data register, and an address register walking the table, each row's offset written
            # through it and the register moved on in the same instruction, MOVE.W D0,(A1)+. In work
            # RAM, the row is read for the block, read again to find its slot, added to and compared
            # there on every row; in a register each of those is a quarter of the time or less, and
            # the slot costs nothing to find (M68000 User's Manual, "Instruction Execution Times":
            # a long read through d16(An) 16 cycles against 4 from a data register, ADDQ.L 20 cycles
            # on memory against 8 on a register). The rows left are counted down in D6 by DBRA, which
            # takes one from it and branches in one instruction, 10 cycles, where a compare and a
            # branch take 18.
            #
            # What the block reads and never writes is held too, as such a loop holds it: up to two of
            # its variables in D3 and D4, read from work RAM once before the rows, and up to two of
            # its tables' addresses in A2 and A3, so a row reads the entry through the register with
            # no LEA of the table's address first.
            #
            # It is done where the block allows it, as a loop's count is held (#with_counter_held):
            # every step of it, and its answer, are written in place with D0, D1, D2 and A0 alone, so
            # nothing it calls can overwrite the registers held and no pass can end inside it, and
            # none of its steps writes the row. The row goes back to its variable once the rows are
            # done, so what comes after reads it as before.
            def emit_bend_rows_held(bend, first, past)
              register, left = COUNTER_REGISTERS.first(2).map { |number| @asm.d(number) }
              top = fresh("bend_row")
              @asm.moveq(first, register)
              @asm.move(:w, @asm.imm(past - first - 1), left)
              @asm.lea(at(bend_table(bend), first * 2), @asm.a(1))
              hold_bend_reads(bend)
              @counters_held[bend.row] = register
              # Must be held as a count is, so a loop in the block takes the register after it.
              @counters_held[BEND_ROWS_LEFT] = left
              @indexes_checked.delete(bend.row)
              begin
                place_label(top)
                with_index_below(bend.row, past) do
                  bend.body.each { |child| statement(child) }
                  emit_bend_offset(bend.offset)
                end
                @asm.move(:w, @asm.d(0), @asm.post(1))
                # The row runs from +first+ up to +past+, never above a word, and only this loop
                # writes the register, so its low word is the whole of it.
                @asm.addq(:w, 1, register)
                @asm.dbra(left, top)
              ensure
                @counters_held.delete(bend.row)
                @counters_held.delete(BEND_ROWS_LEFT)
                @reads_held = nil
                @tables_held = nil
              end
              @asm.move(:l, register, var(bend.row))
            end

            # A table read whose index is a masked sum, which the rows can work out in words: the table, how its
            # entries are kept, the two sides of the sum (each a number, a [:imm, number], or a data register, a
            # [:reg, operand]), and the mask.
            WordTableRead = Data.define(:table, :bytes, :signed, :sum, :mask)

            # The row's answer in D0. The rows keep only the low word of it, so a table read whose index is a
            # masked sum of held numbers is worked out at word width, as a 68000 line loop is written: the sum
            # added as words, masked with an immediate (an AND.W of an immediate, not a MOVEQ and an AND.L), and
            # the entry read as a word. With a mask of no more than 15 bits, only the low 16 bits of the sum
            # matter, so the word sum gives the interpreter's index. Anything else is worked out as a value.
            def emit_bend_offset(node)
              read = word_table_read(node)
              return value(node) unless read

              first, second = read.sum.sort_by { |kind, _| kind == :reg ? 0 : 1 }.map(&:last)
              @asm.move(:w, first.is_a?(Integer) ? @asm.imm(first & 0xFFFF) : first, @asm.d(0))
              @asm.add(:w, second.is_a?(Integer) ? @asm.imm(second & 0xFFFF) : second, @asm.d(0)) if second
              @asm.and(:w, @asm.imm(read.mask), @asm.d(0))
              base = @tables_held&.fetch(node.name, nil)
              @asm.lea(@asm.abs_l(table_label(read.table.name)), @asm.a(0)) unless base
              if read.bytes == 2
                @asm.add(:w, @asm.d(0), @asm.d(0))
                @asm.move(:w, @asm.idx(base || 0, 0, 0, :w), @asm.d(0))
              else
                @asm.move(:b, @asm.idx(base || 0, 0, 0, :w), @asm.d(0))
                @asm.ext(:w, @asm.d(0))
              end
            end

            # The WordTableRead +node+ is, or nil: a table of words (or signed bytes) read at a masked sum, its
            # index sure to be inside the table by its mask, where each side of the sum is a number or a variable
            # held in a data register, and at least one is. A variable in work RAM is not taken: a word read
            # from its address would be its high word, the 68000 being big-endian.
            def word_table_read(node)
              return unless node.is_a?(Node) && node.kind == :table_get

              table = @tables[node.name] or return
              count = table.values.length
              bytes, signed = table_keeping(table)
              return unless bytes == 2 || (bytes == 1 && signed)
              return unless count * bytes <= 0x7FFF

              index = node.index
              return unless index.is_a?(Node) && index.kind == :binop && index.op == :&

              mask = folded(index.rhs)
              return unless mask.is_a?(Integer) && mask.between?(0, 0x7FFF) && mask < count

              sum = index.lhs
              return unless sum.is_a?(Node) && sum.kind == :binop && sum.op == :+

              sides = [sum.lhs, sum.rhs].map { |side| word_sum_side(side) }
              return if sides.any?(&:nil?) || sides.none? { |kind, _| kind == :reg }

              WordTableRead.new(table: table, bytes: bytes, signed: signed, sum: sides, mask: mask)
            end

            # One side of a masked sum: [:imm, its number] for a number written in the program, [:reg, its
            # register] for a variable held in a data register, nil for anything else.
            def word_sum_side(side)
              known = folded(side)
              return [:imm, known] if known.is_a?(Integer)

              held = operand_of(side)
              [:reg, held] if held && held.mode == :dn
            end

            # The data registers a bend's rows hold the block's variables in, and the address
            # registers they hold its tables' addresses in (#emit_bend_rows_held).
            BEND_READ_REGISTERS = [3, 4].freeze
            BEND_TABLE_REGISTERS = [2, 3].freeze

            # The rows left, held beside the row: a name no variable of a game's has.
            BEND_ROWS_LEFT = :"bend rows left"

            # The block's variables and tables held for its rows, each loaded into its register.
            def hold_bend_reads(bend)
              nodes = bend_nodes(bend)
              written = bend_writes(nodes)
              read = nodes.filter_map { |node| node.kind == :copy ? node.src : (node.name if node.kind == :var_ref) }
              held = (read.uniq - written - [bend.row]).first(BEND_READ_REGISTERS.length)
              @reads_held = held.zip(BEND_READ_REGISTERS).to_h do |name, number|
                @asm.move(:l, var(name), @asm.d(number))
                [name, @asm.d(number)]
              end
              tables = nodes.filter_map { |node| node.name if node.kind == :table_get }.uniq.first(BEND_TABLE_REGISTERS.length)
              @tables_held = tables.zip(BEND_TABLE_REGISTERS).to_h do |name, number|
                @asm.lea(@asm.abs_l(table_label(@tables.fetch(name).name)), @asm.a(number))
                [name, number]
              end
            end

            # Every node of +bend+'s block and its answer.
            def bend_nodes(bend) = [*bend.body, bend.offset].grep(Node).flat_map { |part| part.walk.to_a }

            # The variables the steps among +nodes+ write: what each sets, and a loop's count.
            def bend_writes(nodes)
              nodes.flat_map { |node| [LightScenes.written_var(node), (node.index if node.kind == :repeat)] }.compact
            end

            # Can +bend+'s rows be worked out with the row held (#emit_bend_rows_held)? Only with
            # no other count held, as the rows are worked out at a wait, outside every loop, and with
            # no walk of a pool in the block: a held walk (#emit_stepped_walk) keeps its place in D3,
            # D4, A3 and A4, which are the reads' and the tables' here.
            def bend_rows_held?(bend)
              @counters_held ||= {}
              nodes = bend_nodes(bend)
              @counters_held.empty? && !@held_walk &&
                bend.body.all? { |child| statement_keeps_counters?(child) } && value_keeps_counters?(bend.offset) &&
                !bend_writes(nodes).include?(bend.row) && nodes.none? { |node| node.kind == :repeat && node.pool_walk }
            end

            # The rows' loop stops with the variable at the height; a game that never waits leaves it at
            # the last row painted.
            def emit_row_variable_set(bend, height)
              statement(Build.set(bend.row, height - 1)) if @painting_bends
            end

            # The offset of the row in the bend's variable, its low word, kept at that row of the bend's
            # table. The chip takes the scroll's low ten bits, so the low word is all a row needs.
            def emit_row_offset_kept(bend)
              value(bend.offset)
              @asm.move(:l, var(bend.row), @asm.d(1))
              @asm.add(:w, @asm.d(1), @asm.d(1)) # two bytes a row
              @asm.lea(at(bend_table(bend)), @asm.a(0))
              @asm.move(:w, @asm.d(0), @asm.idx(0, 0, 1, :w))
            end

            # Where a bend's rows are kept as a wait works them out: a word for each line of the screen.
            def bend_table(bend)
              (@bend_tables ||= {})[bend.background] ||=
                @memory.reserve("the bend of #{bend.background.inspect}", Console::GENESIS.screen_height * 2)
            end

            # The plane +plane+ shows +bg+'s bend from here on, or none: +bg+ nil for a plane left empty.
            # A game that bends nothing notes none.
            def emit_bend_shown(plane, bg)
              return if bends.empty?

              bend = bg && @plan.row_bends.bend_for(bg.name)
              place = runtime_at(Runtime::Tiles::BENDS_SHOWN, plane * 4)
              return @asm.clr(:l, place) unless bend

              @asm.lea(at(bend_table(bend)), @asm.a(0))
              @asm.move(:l, @asm.a(0), place)
            end
          end
        end
      end
    end
  end
end
