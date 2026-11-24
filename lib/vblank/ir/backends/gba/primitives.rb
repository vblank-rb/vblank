# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Small shared primitives: variable addresses, stores, constant folding.
        class Primitives
          include Console::Hardware

          # The word a fill reads its colour from. The console's copying engine fills by
          # reading the same word over and over, so a fill stores its colour in this one
          # and hands the engine the word's ADDRESS — as a number, built by instructions.
          FILL_SCRATCH = :_dma_scratch

          def initialize(emitter:, memory:)
            @emitter = emitter
            @memory = memory
            @vars = {}             # variable name -> IWRAM address
            @var_mentions = []     # [where in the code, variable name], one for each time one is named
            @held_registers = {}
          end

          # The fill's word gets the first address there is, so this is called before the
          # program has named anything. How many instructions a number takes depends on its
          # bits, and the first address of this memory is the only one the chip builds in a
          # single instruction; most of the others take two or three. Handed out on first
          # mention like everything else, the word landed wherever the variables named before
          # the first fill left it, so what every fill in a game cost was settled by something
          # nobody chose. A program that never fills spends one word of memory on it.
          def claim_first_address_for_fill_scratch
            var_addr(FILL_SCRATCH)
          end

          # Every variable's allocated address (name => address) — read by GBA#var_addresses.
          attr_reader :vars

          # A variable is 4 bytes in IWRAM, addresses handed out on first mention — and
          # handed out at the near end, which is what keeps them inside the window the
          # note below is about. See {Memory}.
          def var_addr(name)
            @var_mentions << [@emitter.pos, name]
            @vars[name] ||= roomy_var?(name) ? claim_roomy_var(name) : @memory.alloc_near_base(4)
          end

          # A variable a collection owns goes where the collection went. A list keeps how many
          # items it holds, and a pool a dozen more of its own (see Lists#roomy_counter?); a
          # collection kept in the roomy memory, because the author marked it as cold or because
          # the quick one ran out, would otherwise leave those behind in the quick memory, where
          # every one of them is a word the code kept there cannot have. Reaching one there costs
          # its whole address, which the collection's own items already cost.
          #
          # +lists+ (Lists, which knows where the collections went) answers whether a name is one
          # of those; it is built after this, and handed in then.
          attr_writer :lists

          def roomy_var?(name) = @lists&.roomy_counter?(name) || false

          # Give +name+ a place in the roomy memory, before anything names it. The build's second
          # pass asks this for each variable its measuring pass put there, since it names them
          # before it has placed the collections that decide it (see
          # Placement#allocate_variables_where_measured).
          def claim_roomy_var(name)
            @vars[name] ||= @memory.alloc_roomy_var ||
                            raise(LoweringError, "The console's roomy memory is full. A list or pool kept there " \
                                                 "needs room for one more number of its own. To fix this, use " \
                                                 "a smaller capacity, or narrower items (`width: :byte`).")
          end

          # The variables named anywhere in +span+ of the code, each once, in the order they
          # were first named there. This is how the build learns which variables a routine
          # uses, the ones it made for itself included.
          def variables_named_in(span)
            @var_mentions.filter_map { |pos, name| name if span.cover?(pos) }.uniq
          end

          # How far from the base a variable can sit and still be reached by naming the two
          # together. The instruction keeps twelve bits for the distance, so a thousand
          # variables. Past that the address is built in full, as everything used to be.
          FURTHEST_FROM_BASE = 0xFFF

          # Reading a variable is two instructions, and often one: put the base of the variable
          # memory in a register, then load from that register plus this variable's distance
          # along — and skip the first of those when the base is still sitting there from the
          # last access.
          #
          # It used to be the whole address and then a load, and the whole address is the
          # expensive part. This console can name a number in one instruction only when the
          # number has eight significant bits in the right places, which an address does not,
          # except by luck: the first variable sits at the base itself and costs one, the next
          # sixty-three cost two, and everything past that costs three. So the hundredth variable
          # a program declares was read in four instructions and the first in two, for no reason
          # the program could see — it was the order the backend happened to emit things in.
          #
          # The base is a number this console can name in one instruction, and the distance rides
          # inside the load. So every variable is two, and the hundredth costs what the first
          # does. And since the base never changes for the life of the program, a run of accesses
          # with nothing between them that could disturb the register needs it made only once —
          # which is most of a run of arithmetic, where the whole of the work between two
          # variables is an add or a compare. What knows when it is still there is
          # {AddressRegister}, which is careful about it, because being wrong writes to the
          # wrong address rather than failing.
          #
          # A variable the code around us is already holding in a register is one move instead,
          # and it is the same number either way because whoever holds it is keeping memory and
          # register in step (see Statements#emit_repeat, the only holder today: a loop's index).
          def load_var(reg, name)
            held = held_register(name)
            return @emitter.emit(ASM.mov_reg(reg, held)) if held

            offset = var_offset(name)
            return @emitter.emit(ASM.ldr_offset(reg, ADDR, offset)) if emit_var_address_base(offset)

            @emitter.emit(ASM.ldr(reg, ADDR))
          end

          def store_var(reg, name)
            offset = var_offset(name)
            return @emitter.emit(ASM.str_offset(reg, ADDR, offset)) if emit_var_address_base(offset)

            @emitter.emit(ASM.str(reg, ADDR))
          end

          def var_offset(name) = var_addr(name) - IWRAM_START

          # The register a variable is being held in for the moment, or nil. Kept as a plain
          # map rather than an allocator: exactly one thing puts anything in it, and it puts
          # the entry back the way it found it.
          def held_register(name) = @held_registers[name]

          # For a moment, read this variable from its memory rather than from the register that
          # was holding it — because the register is about to be lent to something else and put
          # back afterwards (see Statements#emit_bracketed).
          def without_var_in_register(name, &block) = with_var_in_register(name, nil, &block)

          def with_var_in_register(name, reg)
            was = @held_registers[name]
            @held_registers[name] = reg
            yield
          ensure
            @held_registers[name] = was
            @held_registers.delete(name) if was.nil?
          end

          # Store the full 32-bit word in r0 to a fixed address.
          def store_word_acc(address)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # Store the low 16 bits of r0 to a fixed address — for a register that is a
          # halfword wide and holds a value the program worked out as it ran.
          def store_halfword_acc(address)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # The block's instructions with the interrupt switch off, for a read and a write (or two
          # writes) an interrupt handler must not land between (GBATEK, Interrupt Control: IME,
          # 0x4000208, bit 0 off holds every interrupt; one asked for meanwhile waits in IF and is
          # taken as IME comes back on). Kept to the few instructions that need it. The block may
          # use TMP and ADDR; the switch as it was waits on the stack.
          def with_interrupts_held_off
            @emitter.emit_number(TMP, REG_IME)
            @emitter.emit(ASM.load_halfword(ADDR, TMP))
            @emitter.emit(ASM.push(ADDR))
            @emitter.emit_number(ADDR, 0)
            @emitter.emit(ASM.store_halfword(ADDR, TMP))
            yield
            @emitter.emit(ASM.pop(ADDR))
            @emitter.emit_number(TMP, REG_IME)
            @emitter.emit(ASM.store_halfword(ADDR, TMP)) # the interrupt switch as it was
          end

          # Whether code the game runs from an interrupt can copy or fill (InterruptCopies.any?).
          # Set by GBA#lower before anything is emitted. Only then can a handler use the copying
          # engine while the game is part way through setting it up, so only then is a setup held.
          attr_writer :interrupts_copy

          def interrupts_copy? = @interrupts_copy

          # How far the interrupt switch (IME) sits from the copying engine's first register, so
          # a setup that has the engine's address in a register reaches the switch for nothing.
          IME_STEP = REG_IME - REG_DMA3SAD

          STACK_POINTER = 13 # sp

          # The block's writes to the copying engine with the interrupt switch off, in a game whose
          # interrupts run its own code.
          #
          # ### Why a setup is held
          #
          # The engine (DMA3) is set up by three writes: where from, where to, then the control
          # word, whose enable bit starts the copy (GBATEK, "DMA Transfers"). An interrupt can come
          # between any two instructions (GBATEK, "Interrupt Control"). A handler that copies writes
          # its own from, to and control and starts its own copy, and the game then writes the rest
          # of its setup over the handler's and starts a copy from or to the wrong place. The
          # engine's registers are write-only, so the handler cannot save and put them back; the
          # setup is held instead. The interrupt switch, IME at 4000208h, holds every interrupt while
          # bit 0 is off, and one that came meanwhile waits in IF and is taken as the switch comes
          # back on. The copy itself already holds interrupts while it runs, since the processor is
          # stopped until it ends (GBATEK, "DMA Transfers"), so the hold adds only the few
          # instructions of the setup.
          #
          # The switch is put back as it was, not on, so a setup inside a stretch that already
          # holds interrupts leaves them held. +engine+ holds the engine's first address
          # (REG_DMA3SAD) and the block keeps it; +spare+ is free as the block starts and once it
          # ends, and the switch as it was waits on the stack between. The switch is read and
          # written as a word, with the unused halfword beside it (GBATEK, I/O map: 400020Ah).
          # Five instructions for each setup, and none in a game whose interrupt code never copies.
          def with_copy_setup_held(engine:, spare:)
            return yield unless @interrupts_copy

            @emitter.emit(ASM.ldr_offset(spare, engine, IME_STEP))
            @emitter.emit(ASM.push(spare))
            @emitter.emit(ASM.load_immediate(spare, 0))
            @emitter.emit(ASM.str_offset(spare, engine, IME_STEP))
            yield
            @emitter.emit(ASM.pop(spare))
            @emitter.emit(ASM.str_offset(spare, engine, IME_STEP)) # the interrupt switch as it was
          end

          # The interrupt switch turned off, as #with_copy_setup_held turns it, for code that keeps
          # its numbers on the stack at fixed places and so cannot push the switch as it was: it is
          # kept in the stack slot +saved_at+ bytes up, which the caller set aside.
          # #emit_copies_let_through puts it back. Nothing in a game whose interrupt code never copies.
          def emit_copies_held(engine:, spare:, saved_at:)
            return unless @interrupts_copy

            @emitter.emit(ASM.ldr_offset(spare, engine, IME_STEP))
            @emitter.emit(ASM.str_offset(spare, STACK_POINTER, saved_at))
            @emitter.emit(ASM.load_immediate(spare, 0))
            @emitter.emit(ASM.str_offset(spare, engine, IME_STEP))
          end

          def emit_copies_let_through(engine:, spare:, saved_at:)
            return unless @interrupts_copy

            @emitter.emit(ASM.ldr_offset(spare, STACK_POINTER, saved_at))
            @emitter.emit(ASM.str_offset(spare, engine, IME_STEP)) # the interrupt switch as it was
          end

          # The block, run from an interrupt, with the fill's colour word saved around it. A fill
          # writes its colour to that one word and then hands the copying engine its address, row
          # after row, so a handler that fills between two of the game's rows would leave its own
          # colour for the rest of them. Uses the accumulator, which a handler may spend, and one
          # word of the interrupt stack (TopOfQuickMemory::HANDLER_OWN_BYTES).
          def with_fill_word_saved
            load_var(ACC, FILL_SCRATCH)
            @emitter.emit(ASM.push(ACC))
            yield
            @emitter.emit(ASM.pop(ACC))
            store_var(ACC, FILL_SCRATCH)
          end

          # Write a full 32-bit word to an address.
          def store_word_immediate(value, address)
            @emitter.emit_number(ACC, value)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # A value that is already waiting in a register, for {#emit_start_copy_engine}: that
          # register is written as it stands, where a plain number is loaded first.
          InRegister = Data.define(:register)

          # How far along from the first of the copying engine's three registers the other
          # two sit.
          COPY_TO_STEP = REG_DMA3DAD - REG_DMA3SAD
          COPY_START_STEP = REG_DMA3CNT - REG_DMA3SAD

          # Tell the copying engine what to copy, and start it. The console has an engine that
          # moves a block of memory on its own, far faster than a loop of loads and stores, and
          # it is told what to do through three registers: where to copy +from+, where +to+,
          # and a +control+ word saying how much and in what manner. Writing the control word
          # is what starts it, so that one always goes last.
          #
          # The three sit side by side in memory, which is why this is one call and not three
          # stores. An address is the dear part of a store on this chip — two instructions to
          # build, where the store itself is one — and a store can name a small step from the
          # address it is given for nothing. So the first address is built once and the other
          # two are reached from it: two instructions for the three, not six. A game starts
          # this engine wherever it clears, fills, copies a row or sends a picture, so it is a
          # sequence written out hundreds of times over.
          #
          # Each of the three is one of:
          #
          #   * a number settled while building, which is loaded and written;
          #   * an {InRegister}, written from where it waits;
          #   * a block that leaves the number in the accumulator — an address filled in
          #     later, a size not known yet — which is run and then written.
          #
          # Numbers pass through the accumulator on their way, so anything already waiting in
          # a register is written before the first of them. That is the only reordering, and
          # the engine does not care which of its two ends it hears about first.
          def emit_start_copy_engine(from:, to:, control:)
            refuse_copy_engine_register_clash!(from, to, control)
            refuse_copy_of_nothing!(control)
            @emitter.emit_number(TMP, REG_DMA3SAD)
            # What a block must leave alone: the engine's address, and a control word that is
            # still waiting for its turn.
            kept = [TMP, *(control.register if control.is_a?(InRegister))]
            waiting, loaded = [[from, 0], [to, COPY_TO_STEP]].partition { |value, _| value.is_a?(InRegister) }
            with_copy_setup_held(engine: TMP, spare: ADDR) do
              (waiting + loaded).each { |value, step| emit_copy_engine_store(value, step, kept) }
              emit_copy_engine_store(control, COPY_START_STEP, kept)
            end
          end

          # The value of an operand the author fixed, or nil if the game works it out. The
          # same question the surface asks, so the two cannot disagree about what counts as
          # fixed; what this adds is the console's own arithmetic, where a number is signed
          # and thirty-two bits wide.
          def self.const_int(node)
            fixed = DSL::Value.fixed_number(node)
            Int32.wrap(fixed) if fixed
          end

          def const_int(node) = self.class.const_int(node)

          # Each named operand as a number settled while building, in the order given. The
          # caller passes the values along with what to call them, because the name is only
          # wanted for the message if one of them turns out to be worked out as the game runs.
          def constant_ints!(node, **sides)
            sides.map do |name, value|
              const_int(value) ||
                raise(LoweringError,
                      "the GBA backend needs a constant #{name} for #{node.kind} " \
                      "(a computed one is the runtime-rect work, tracked separately)")
            end
          end

          # Run +body+ once per row of a rect whose height the program works out as it
          # runs. +counter+ is the register holding how many rows are left; +body+ emits
          # one row and must leave the counter alone.
          #
          # The count is tested before the first row, which is what makes a height of
          # zero — or a negative one, from a bar that ran past empty — draw nothing
          # instead of wrapping round to four thousand million rows.
          #
          # ...and after that only at the bottom of each row. Taking one off the count can set
          # the chip's flags as it goes, so "is there another row?" is the subtract and one
          # branch back. Tested at the top as well, every row would pay a compare, a branch out
          # that is not taken, and a branch back: two instructions a row more for the same walk.
          def emit_row_loop(counter)
            top = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(counter, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)
            @emitter.place_label(top)
            yield
            @emitter.emit(ASM.subs_imm(counter, counter, 1))
            @emitter.emit_branch(:bcond, top, cond: :gt)
            @emitter.place_label(done)
          end

          # rd = rn + imm. A small immediate rides directly in the ADD; a larger one
          # (a wide bitmap's row offset, say) is loaded into +scratch+ first, since
          # ARM can only fold an 8-bit rotated immediate into the instruction.
          def emit_add_const(rd, rn, imm, scratch)
            if imm.zero?
              @emitter.emit(ASM.mov_reg(rd, rn)) unless rd == rn
            elsif ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.add_imm(rd, rn, imm))
            else
              @emitter.emit_number(scratch, imm)
              @emitter.emit(ASM.add_reg(rd, rn, scratch))
            end
          end

          # Put an address in an address register, as cheaply as what is already in there
          # allows. Three prices, and the caller writes the same line for all three:
          #
          #   * Nothing at all, when the register already holds it. This is the case that
          #     matters — a run of accesses to the same thing names its address once.
          #   * ONE instruction, when the register holds another address near enough that
          #     the step between them is a number this chip can name outright. Two lists
          #     side by side in memory — which is what a pool's fields are — are a step
          #     apart of exactly one list's length, so walking from one field to the next
          #     is an add rather than an address built from scratch.
          #   * The address in full: built a byte at a time, or, in a routine kept in the
          #     quick memory, read from that routine's table of numbers (Emit#emit_number).
          #
          # Being WRONG here writes to the wrong place rather than failing, so what may be
          # believed about the register is decided in one place ({AddressRegister}) and
          # this only spends it. Note the order: the instruction is emitted first and the
          # new value recorded after, because emitting it is itself what makes the old
          # value untrue.
          def emit_load_address_register(address, reg = ADDR, held = @emitter.address_register)
            return if held.holds?(address)

            step = held.value && address - held.value
            if step && ASM.encode_rotated_immediate(step.abs)
              @emitter.emit(step.negative? ? ASM.sub_imm(reg, reg, -step) : ASM.add_imm(reg, reg, step))
            else
              @emitter.emit_number(reg, address)
            end
            held.now_holds(address)
          end

          # The same, for a collection's own base — which waits in a register of its own so
          # that the variables and the collections are not forever pushing each other out of
          # one. See {LIST_ADDR}.
          def emit_list_base(address) = emit_load_address_register(address, LIST_ADDR, @emitter.list_register)

          # The register and distance a load or store of the slot at +address+, in the list whose
          # first slot is at +list_base+, names. A slot near enough the variables is reached from
          # their base, as a variable is, so a read of `shown[1]` costs what a read of a variable
          # costs; one further away is reached from the list's own base.
          def emit_fixed_slot_base(address, list_base)
            near = address - IWRAM_START
            return [ADDR, near] if near.between?(0, FURTHEST_FROM_BASE) && emit_var_address_base(near)

            emit_list_base(list_base)
            [LIST_ADDR, address - list_base]
          end

          # rd = rn & imm — the ring-wrap mask. A mask that fits an 8-bit rotated
          # immediate (capacity up to 256) rides directly in the AND; a wider one is
          # loaded into +scratch+ first, since ARM can't fold it into the instruction.
          def emit_and_const(rd, rn, imm, scratch)
            if ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.and_imm(rd, rn, imm))
            else
              @emitter.emit_number(scratch, imm)
              @emitter.emit(ASM.and_reg(rd, rn, scratch))
            end
          end

          private

          # One of the engine's three registers, +step+ along from the first, whose address
          # is waiting in TMP. +kept+ is the registers a block has to leave as they are.
          def emit_copy_engine_store(value, step, kept)
            return @emitter.emit(ASM.str_offset(value.register, TMP, step)) if value.is_a?(InRegister)

            if value.respond_to?(:call)
              before = [@emitter.pos, @emitter.branches]
              value.call
              refuse_copy_engine_block_overwrite!(*before, kept)
            else
              @emitter.emit_number(ACC, value)
            end
            @emitter.emit(ASM.str_offset(ACC, TMP, step))
          end

          # Being wrong here writes to the wrong place and says nothing, so the ways a caller
          # could lose a number are refused while building. TMP holds the engine's address
          # from the first store to the last, and the accumulator is what every loaded number
          # passes through — so a control word waiting there would be gone by the time it was
          # written. (What a block may write is checked once it has run; see below.)
          def refuse_copy_engine_register_clash!(from, to, control)
            waiting = [from, to, control].grep(InRegister)
            if waiting.any? { |value| value.register == TMP }
              raise ArgumentError, "the copying engine's own address is kept in r#{TMP}, so a number " \
                                   "for it cannot wait there"
            end
            if waiting.any? { |value| value.register == ADDR }
              raise ArgumentError, "the interrupt switch as it was passes through r#{ADDR} while the copying " \
                                   "engine is set up (#with_copy_setup_held), so a number for it cannot wait there"
            end
            return unless control == InRegister.new(ACC) && waiting != [from, to, control]

            raise ArgumentError, "the control word cannot wait in r#{ACC}: the numbers written before " \
                                 "it are loaded through that register"
          end

          # The low half of the engine's control word: how many units it moves.
          COPY_COUNT_MASK = 0xFFFF

          # A count of nought is the engine's biggest count, not nothing (GBATEK, DMA word count:
          # "0 = 4000h" for the first three engines, "0 = 10000h" for this one). Asked to move
          # nothing it moves 65,536 units, more than all of video memory holds, from wherever its
          # source was over whatever follows its destination. A copy whose count is settled while
          # building and comes to nought is a lowering that forgot to leave the copy out, so it
          # is refused here, naming the methods that asked (the first two, since the nearest is
          # often a one-line pass-through), before such a cartridge can be made. A count the game
          # works out as it runs is the caller's to test before the copy. The few places that
          # write the control word by hand ask this too.
          def self.refuse_copy_of_nothing!(control, askers = caller_locations(1, 2))
            return unless control.is_a?(Integer) && (control & COPY_COUNT_MASK).zero?

            named = askers.map { |place| "#{place.label} (#{File.basename(place.path)}:#{place.lineno})" }
            raise ArgumentError, "#{named.join(', called by ')} started the copying engine with a count of " \
                                 "nought, which it reads as 65,536: leave the copy out when there is " \
                                 "nothing to copy"
          end

          def refuse_copy_of_nothing!(control)
            askers = caller_locations(2..).drop_while { |place| place.base_label == "emit_start_copy_engine" }
            self.class.refuse_copy_of_nothing!(control, askers.first(2))
          end

          # A block that works a number out must leave the +kept+ registers as they are, and
          # that has to be something its instructions can be read for. A jump or a call cannot
          # be: each is a placeholder until the second pass, and a call reaches a routine that
          # uses the registers for work of its own. So a block is a straight run or it is
          # refused.
          def refuse_copy_engine_block_overwrite!(start, branches, kept)
            if @emitter.branches != branches
              raise ArgumentError, "working out a number for the copying engine jumped or called, so " \
                                   "what it left in the registers cannot be checked"
            end
            written = @emitter.code.byteslice(start, @emitter.pos - start).unpack("V*")
            lost = kept.find { |register| written.any? { |word| ASM.may_write_register?(word, register) } }
            return unless lost

            raise ArgumentError, "working out a number for the copying engine wrote r#{lost}, which " \
                                 "holds a number the engine has not been given yet"
          end

          # Put what the load will be read from into the address register: the base of the
          # variable memory when the variable is near enough to it, and the variable's own
          # address when it is not. Answers whether the distance still has to be named.
          def emit_var_address_base(offset)
            near = offset.between?(0, FURTHEST_FROM_BASE)
            emit_load_address_register(near ? IWRAM_START : IWRAM_START + offset)
            near
          end
        end
      end
    end
  end
end
