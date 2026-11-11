# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE PLAYSTATION'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the MIPS R3000A, written
        # so the lowering reads like the assembly a person would write and never spells out an opcode by
        # hand.
        #
        # The R3000A is a 32-bit processor with 32 registers of 32 bits each. Register 0 (`zero`) always
        # reads 0, and writing to it does nothing. Every instruction is one 32-bit word, written low byte
        # first, and does one small thing: add two registers into a third, load a word from memory into a
        # register, branch if two registers are equal. Memory is only reached by loads and stores, each
        # naming a register that holds an address and a signed 16-bit distance from it (`lw t0, 4(sp)`).
        # A number wider than 16 bits is built in two steps: LUI puts 16 bits in the top half, and ORI
        # (or ADDIU) the low half.
        #
        # TWO THINGS THIS PROCESSOR DOES THAT SURPRISE A READER, both from its five-stage pipeline, and
        # both taken care of here so the lowering never has to think about them:
        #
        # - THE BRANCH DELAY SLOT. "The instruction following the branch will always be executed" (psx-spx,
        #   CPU): by the time the processor knows it must jump, it has already fetched the next
        #   instruction, and it runs it. A caller can hand a branch a block whose one instruction goes in
        #   that slot. Handed none, the branch takes the instruction written just before it, where that
        #   comes to the same thing (#take_slot_filler), and a NOP where it does not.
        # - THE LOAD DELAY SLOT. "The loaded data is NOT available to the next opcode" (psx-spx, CPU): a
        #   load's value arrives one instruction late, and the instruction right after it still sees the
        #   register's old value. The assembler remembers the register the last instruction loaded, and
        #   puts a NOP first when the next one reads it. A label after a load gets one too, since a place
        #   other code jumps to cannot know what came before it.
        #
        # MULTIPLY AND DIVIDE do not write a register: they leave their answer in two registers of their
        # own, HI and LO, read with MFHI and MFLO. On MIPS I a multiply or divide started within two
        # instructions of reading HI or LO can change what that read gets, so two instructions stand
        # between (NOPs when nothing else does).
        #
        # ADD and ADDI stop the processor with an exception when the sum overflows, which a game's number
        # never must (it wraps, IR::Int32). This assembler only has ADDU, ADDIU and SUBU, which wrap.
        #
        # An Assembler writes one Section: a run of bytes with names for places in it (labels) and holes
        # still to fill (fixups) where an instruction names a place that may be in another section. The
        # Linker puts the sections in RAM and fills the holes.
        #
        #   asm.lw(:t0, 8, :gp)              # lw   t0, 8(gp)
        #   asm.addu(:v0, :t0, :t1)          # addu v0, t0, t1
        #   asm.bne(:v0, :zero, "loop")      # bne  v0, zero, loop ; nop
        class R3000
          # Raised for an instruction the processor does not have, or a number that does not fit one — a
          # mistake in the lowering.
          class Error < StandardError; end

          # A place named in an instruction, filled in once everything is placed (Sections::Fixup). Its
          # +kind+ here is :branch16 (the distance in instructions from the one after a branch, signed 16
          # bits), :jump26 (an address within the same 256 megabytes, in words), :hi16 and :lo16 (the top
          # and bottom halves of an address, for LUI then ORI) and :abs32 (a whole address as data).
          Fixup = Sections::Fixup
          Section = Sections::Section
          Holding = Sections::Holding

          # The registers by their usual names. `at` is kept for the assembler's own use by convention;
          # `k0` and `k1` belong to the interrupt handler, which may change them at any moment.
          REGISTERS = %i[zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7
                         s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra].each_with_index.to_h.freeze

          # The instructions of the shape `op rd, rs, rt`, by their function number (the low six bits).
          THREE_REGISTERS = { addu: 0x21, subu: 0x23, and: 0x24, or: 0x25, xor: 0x26, nor: 0x27, slt: 0x2A,
                              sltu: 0x2B }.freeze
          # `op rd, rt, rs`: a shift by a count held in a register.
          VARIABLE_SHIFTS = { sllv: 0x04, srlv: 0x06, srav: 0x07 }.freeze
          # `op rd, rt, count`: a shift by a count written in the instruction.
          SHIFTS = { sll: 0x00, srl: 0x02, sra: 0x03 }.freeze
          # `op rs, rt` into HI and LO.
          MULTIPLY_DIVIDE = { mult: 0x18, multu: 0x19, div: 0x1A, divu: 0x1B }.freeze
          # `op rt, rs, number`: the number signed (sign) or not (zero), and its opcode.
          SIGNED_IMMEDIATES = { addiu: 0x09, slti: 0x0A, sltiu: 0x0B }.freeze
          UNSIGNED_IMMEDIATES = { andi: 0x0C, ori: 0x0D, xori: 0x0E }.freeze
          # `op rt, distance(base)`.
          LOADS = { lb: 0x20, lh: 0x21, lw: 0x23, lbu: 0x24, lhu: 0x25 }.freeze
          STORES = { sb: 0x28, sh: 0x29, sw: 0x2B }.freeze
          # `op rs, rt, label` and `op rs, label`. A REGIMM branch's kind is in the rt field.
          TWO_REGISTER_BRANCHES = { beq: 0x04, bne: 0x05 }.freeze
          ONE_REGISTER_BRANCHES = Ractor.make_shareable({ blez: [0x06, 0], bgtz: [0x07, 0], bltz: [0x01, 0x00], bgez: [0x01, 0x01] })

          # A word to be filled in later, written as noughts.
          ZERO_WORD = "\0\0\0\0".b.freeze

          # The coprocessor 0 (system control) registers the runtime uses: the status register (which
          # interrupts are on), the cause of the last exception, and where it happened.
          COP0_STATUS = 12
          COP0_CAUSE = 13
          COP0_EPC = 14

          attr_reader :bytes

          def initialize(name, home: :any, holds: nil)
            @name = name
            @home = home
            @holds = holds
            @bytes = +"".b
            @labels = {}
            @fixups = []
            @loaded = nil
            @since_hi_lo = 2
            @slot_filler = nil
            @next_is_in_slot = false
          end

          # --- the section ---

          # Where the next byte goes, counted from the start of this section.
          def here = @bytes.bytesize

          # Names the next instruction. A name is the whole program's: two sections cannot share one.
          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            emit_word(0) if @loaded
            @labels[name] = here
            @last_label_at = here
            name
          end

          # Whether a label names the place the next instruction goes: code that jumps there may come from
          # anywhere, so nothing the instructions just before it left in a register can be counted on.
          def labelled_here? = @last_label_at == here

          # The section, padded to a whole number of words so the one placed after it starts on one.
          def section
            bytes = @bytes.dup
            bytes << "\0" until (bytes.bytesize % 4).zero?
            Section.new(name: @name, bytes: bytes.freeze, labels: @labels.dup.freeze, fixups: @fixups.dup.freeze,
                        home: @home, holds: @holds)
          end

          # --- data ---

          # 32-bit words, low byte first; a String is the address of that label.
          def data_words(*values)
            emit_nop_after_load
            values.flatten.each do |value|
              if value.is_a?(String)
                fixup(:abs32, value)
                @bytes << ZERO_WORD
              else
                @bytes << [value & 0xFFFF_FFFF].pack("V")
              end
            end
          end

          def data_halves(*values) = values.flatten.each { |value| @bytes << [value & 0xFFFF].pack("v") }
          def data_bytes(*values) = values.flatten.each { |value| @bytes << [value & 0xFF].pack("C") }

          # Pads with noughts to a multiple of +size+ bytes, so a word read after a run of bytes is aligned.
          def align(size = 4)
            @bytes << "\0" until (here % size).zero?
          end

          # --- arithmetic and logic ---

          # The instructions made from the tables above are written out as plain methods, not made from
          # blocks, so a lowering in a Ractor can call them.
          THREE_REGISTERS.each do |op, function|
            class_eval("def #{op}(rd, rs, rt) = r_type(#{function}, rs: rs, rt: rt, rd: rd)", __FILE__, __LINE__)
          end

          VARIABLE_SHIFTS.each do |op, function|
            class_eval("def #{op}(rd, rt, rs) = r_type(#{function}, rs: rs, rt: rt, rd: rd)", __FILE__, __LINE__)
          end

          SHIFTS.each do |op, function|
            class_eval("def #{op}(rd, rt, count) = emit_shift(:#{op}, #{function}, rd, rt, count)", __FILE__, __LINE__)
          end

          MULTIPLY_DIVIDE.each do |op, function|
            class_eval("def #{op}(rs, rt) = emit_multiply_divide(#{function}, rs, rt)", __FILE__, __LINE__)
          end

          def mfhi(rd) = read_hi_lo(0x10, rd)
          def mflo(rd) = read_hi_lo(0x12, rd)
          def mthi(rs) = r_type(0x11, rs: rs, fills_slot: false)
          def mtlo(rs) = r_type(0x13, rs: rs, fills_slot: false)

          SIGNED_IMMEDIATES.each do |op, opcode|
            class_eval("def #{op}(rt, rs, number) = emit_immediate(:#{op}, #{opcode}, rt, rs, number, -0x8000..0x7FFF)",
                       __FILE__, __LINE__)
          end

          UNSIGNED_IMMEDIATES.each do |op, opcode|
            class_eval("def #{op}(rt, rs, number) = emit_immediate(:#{op}, #{opcode}, rt, rs, number, 0..0xFFFF)",
                       __FILE__, __LINE__)
          end

          def lui(rt, number)
            raise Error, "lui takes 0 to 65535, not #{number}" unless number.between?(0, 0xFFFF)

            i_type(0x0F, rt: rt, immediate: number, writes: rt)
          end

          # A copy of one register in another.
          def move(rd, rs) = addu(rd, rs, :zero)

          # Any 32-bit number into a register, in one instruction where it fits one: ADDIU for a signed
          # 16-bit number, ORI for an unsigned one, LUI alone when the low half is nought.
          def li(rt, number)
            number &= 0xFFFF_FFFF
            signed = number >= 0x8000_0000 ? number - 0x1_0000_0000 : number
            if signed.between?(-0x8000, 0x7FFF) then addiu(rt, :zero, signed)
            elsif number <= 0xFFFF then ori(rt, :zero, number)
            else
              lui(rt, number >> 16)
              ori(rt, rt, number & 0xFFFF) unless (number & 0xFFFF).zero?
            end
          end

          # The address of a label (plus a distance) into a register: LUI with its top half, then ORI with
          # its bottom half, filled in by the Linker.
          def la(rt, label, plus = 0)
            fixup(:hi16, label, plus)
            lui(rt, 0)
            fixup(:lo16, label, plus)
            ori(rt, rt, 0)
          end

          # --- memory ---

          LOADS.each do |op, opcode|
            class_eval("def #{op}(rt, distance, base) = emit_load(:#{op}, #{opcode}, rt, distance, base)", __FILE__, __LINE__)
          end

          STORES.each do |op, opcode|
            class_eval("def #{op}(rt, distance, base) = emit_store(:#{op}, #{opcode}, rt, distance, base)", __FILE__, __LINE__)
          end

          # --- an instruction the code works out, named by its mnemonic ---

          # A load or a store, +op+ one of LOADS or STORES: for a width the code works out.
          def load(op, rt, distance, base) = emit_load(op, LOADS.fetch(op), rt, distance, base)
          def store(op, rt, distance, base) = emit_store(op, STORES.fetch(op), rt, distance, base)

          # `op rd, rs, rt`, +op+ one of THREE_REGISTERS.
          def three_registers(op, rd, rs, rt) = r_type(THREE_REGISTERS.fetch(op), rs: rs, rt: rt, rd: rd)

          # `op rt, rs, number`, +op+ one of SIGNED_IMMEDIATES or UNSIGNED_IMMEDIATES.
          def immediate(op, rt, rs, number)
            if SIGNED_IMMEDIATES.key?(op)
              emit_immediate(op, SIGNED_IMMEDIATES.fetch(op), rt, rs, number, -0x8000..0x7FFF)
            else
              emit_immediate(op, UNSIGNED_IMMEDIATES.fetch(op), rt, rs, number, 0..0xFFFF)
            end
          end

          # --- branches and jumps ---
          #
          # Each takes a block for its delay slot: the one instruction the block emits runs whether the
          # branch is taken or not. Without one, the slot is a NOP. A jump through a register takes
          # `delay: :none` only where a test wants the one word alone.

          TWO_REGISTER_BRANCHES.each do |op, opcode|
            class_eval("def #{op}(rs, rt, target, &slot) = emit_branch(#{opcode << 26}, [rs, rt], target, slot)", __FILE__, __LINE__)
          end

          ONE_REGISTER_BRANCHES.each do |op, (opcode, kind)|
            class_eval("def #{op}(rs, target, &slot) = emit_branch(#{(opcode << 26) | (kind << 16)}, [rs, :zero], target, slot)",
                       __FILE__, __LINE__)
          end

          # Always: BEQ zero, zero.
          def b(target, &) = beq(:zero, :zero, target, &)

          def j(target, &slot) = jump(0x02, target, slot)
          def jal(target, &slot) = jump(0x03, target, slot, links: true)

          def jr(rs, delay: :nop, &slot)
            filler = take_slot_filler([rs]) unless slot || delay == :none
            r_type(0x08, rs: rs, fills_slot: false)
            delay == :none ? leave_slot_to_next_instruction : fill_delay_slot(filler, slot)
          end

          def jalr(rs, delay: :nop, &slot)
            filler = take_slot_filler([rs], links: true) unless slot || delay == :none
            r_type(0x09, rs: rs, rd: :ra, fills_slot: false)
            delay == :none ? leave_slot_to_next_instruction : fill_delay_slot(filler, slot)
          end

          # --- the system ---

          def mfc0(rt, cop0)
            emit(0x40000000 | (register(rt) << 16) | (cop0 << 11))
            @loaded = register(rt) # a coprocessor's register arrives one instruction late, as a load's does
          end

          def mtc0(rt, cop0) = emit(0x40800000 | (register(rt) << 16) | (cop0 << 11), reads: [rt])

          # Return from exception: puts back the interrupts-on state the exception saved. It goes in the
          # delay slot of the JR that leaves the handler.
          def rfe = emit(0x42000010)

          def syscall = emit(0x0000000C)
          def break_code = emit(0x0000000D)
          def nop = emit_word(0)

          private

          def emit_shift(op, function, rd, rt, count)
            raise Error, "#{op} shifts by 0 to 31, not #{count}" unless count.between?(0, 31)

            r_type(function, rt: rt, rd: rd, shift: count)
          end

          def emit_multiply_divide(function, rs, rt)
            emit_word(0) while @since_hi_lo < 2
            r_type(function, rs: rs, rt: rt, fills_slot: false)
          end

          def emit_immediate(op, opcode, rt, rs, number, range)
            raise Error, "#{op} takes #{range.min} to #{range.max}, not #{number}" unless range.cover?(number)

            i_type(opcode, rs: rs, rt: rt, immediate: number, writes: rt)
          end

          def emit_load(op, opcode, rt, distance, base)
            refuse_distance!(op, distance)
            i_type(opcode, rs: base, rt: rt, immediate: distance, writes: rt, fills_slot: false)
            @loaded = register(rt)
          end

          def emit_store(op, opcode, rt, distance, base)
            refuse_distance!(op, distance)
            i_type(opcode, rs: base, rt: rt, immediate: distance, reads: [rt, base])
          end

          # A branch: +word+ with the two registers it compares (rs, then rt) put in, its distance filled in
          # by the Linker, and its delay slot.
          def emit_branch(word, (rs, rt), target, slot)
            filler = take_slot_filler([rs, rt]) unless slot
            fixup(:branch16, target)
            emit(word | (register(rs) << 21) | (register(rt) << 16), reads: [rs, rt])
            fill_delay_slot(filler, slot)
          end

          # The last instruction written, while a branch written next could take it for its slot: where
          # it is, its word, the registers it reads and the one it writes (by number), and the register
          # the instruction before it loaded.
          SlotFiller = Data.define(:at, :word, :reads, :writes, :after_load)

          # THE INSTRUCTION BEFORE A BRANCH, FOR ITS SLOT. The slot runs whether the branch is taken or
          # not, and before whatever the branch goes to, so the instruction written just before a branch
          # can be moved into the slot instead of a NOP: it still runs once, before everything after.
          # What changes is that the branch now decides BEFORE that instruction runs, and a few other
          # things stand where they stood, so it is left alone, and the slot is a NOP, when:
          #
          # - it writes a register the branch reads (+reads+): the branch would test the old value;
          # - a label stands between the two: code jumping there runs the branch alone;
          # - the Linker fills it in (half of an address): the hole is noted where it stands;
          # - it is a load, a read of HI or LO, a multiply or a divide, which are counted from where
          #   they stand (the two delays at the top of this file), or itself in a slot;
          # - the instruction before it loaded a register the branch reads: the branch would then
          #   come straight after the load;
          # - the branch is a call (+links+) and it reads or writes ra: a call writes the way back
          #   into ra as it jumps, before the slot runs.
          #
          # A label naming the instruction itself is fine: it then names the branch, and code jumping
          # there runs the branch and then the slot, the same two instructions.
          #
          # Gives back the instruction's word, taken off the end of the section, or nil.
          def take_slot_filler(reads, links: false)
            filler = @slot_filler
            return unless filler && filler.at == here - 4 && !labelled_here?
            return if @fixups.any? { |fixup| fixup.offset >= filler.at }

            read = reads.map { |name| register(name) } - [register(:zero)]
            return if read.include?(filler.writes) || read.include?(filler.after_load)
            return if links && (filler.writes == register(:ra) || filler.reads.include?(register(:ra)))

            @bytes = @bytes.byteslice(0, filler.at)
            @since_hi_lo -= 1
            @slot_filler = nil
            filler.word
          end

          # The slot after a branch: +filler+, the word #take_slot_filler gave, or what the block emits,
          # or a NOP.
          def fill_delay_slot(filler, slot)
            filler ? emit_word(filler) : delay_slot(slot)
          end

          def register(name)
            REGISTERS.fetch(name) { raise Error, "the R3000 has no register #{name.inspect}" }
          end

          def refuse_distance!(op, distance)
            raise Error, "#{op} reaches -32768 to 32767 bytes, not #{distance}" unless distance.between?(-0x8000, 0x7FFF)
          end

          # +fills_slot+ is whether a branch written next can take this instruction for its slot
          # (#take_slot_filler).
          def r_type(function, rs: :zero, rt: :zero, rd: :zero, shift: 0, fills_slot: true)
            emit((register(rs) << 21) | (register(rt) << 16) | (register(rd) << 11) | (shift << 6) | function,
                 reads: [rs, rt], writes: rd, fills_slot: fills_slot)
          end

          def i_type(opcode, rs: :zero, rt: :zero, immediate: 0, writes: nil, reads: [rs], fills_slot: true)
            reads = [rs] if writes
            emit((opcode << 26) | (register(rs) << 21) | (register(rt) << 16) | (immediate & 0xFFFF), reads: reads,
                                                                                                        writes: writes, fills_slot: fills_slot)
          end

          def read_hi_lo(function, rd)
            r_type(function, rd: rd, fills_slot: false)
            @since_hi_lo = 0
          end

          def jump(opcode, target, slot, links: false)
            filler = take_slot_filler([], links: links) unless slot
            fixup(:jump26, target)
            emit(opcode << 26)
            fill_delay_slot(filler, slot)
          end

          # The instruction the block emits, or a NOP, in the slot after a branch. The slot is the
          # branch's: a block that emits more than one instruction is a mistake.
          def delay_slot(slot)
            emit_nop_after_load
            start = here
            slot ? slot.call : emit_word(0)
            raise Error, "a delay slot holds one instruction, and the block gave #{(here - start) / 4}" unless here - start == 4
            # A load in the slot would arrive late at the branch's target too, where no NOP can be put.
            raise Error, "a load cannot go in a delay slot" if @loaded
            @slot_filler = nil # the slot's instruction is this branch's
          end

          # Puts a NOP after a load when the instruction to come reads what it loaded. +writes+ is the
          # register the instruction writes, and +fills_slot+ whether a branch written next can take it
          # for its slot (#take_slot_filler), which is then told what it reads and writes and the
          # register the instruction before it loaded.
          def emit(word, reads: [], writes: nil, fills_slot: false)
            emit_word(0) if @loaded && reads.any? { |name| name != :zero && register(name) == @loaded }
            after_load = @loaded
            at = here
            in_slot = @next_is_in_slot
            emit_word(word)
            return unless fills_slot && !in_slot

            @slot_filler = SlotFiller.new(at: at, word: word, reads: reads.map { |name| register(name) },
                                          writes: writes && register(writes), after_load: after_load)
          end

          def emit_nop_after_load = (emit_word(0) if @loaded)

          # A jump written with `delay: :none` has the next instruction for its slot, whatever writes
          # it: that one is the jump's, and no later branch may take it for its own.
          def leave_slot_to_next_instruction
            @next_is_in_slot = true
          end

          def emit_word(word)
            @loaded = nil
            @slot_filler = nil
            @next_is_in_slot = false
            @since_hi_lo += 1
            @bytes << [word & 0xFFFF_FFFF].pack("V")
          end

          def fixup(kind, label, plus = 0)
            emit_nop_after_load if %i[branch16 jump26].include?(kind)
            @fixups << Fixup.new(offset: here, kind: kind, label: label.to_s, plus: plus)
          end
        end
      end
    end
  end
end
