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
        #   instruction, and it runs it. Every branch and jump here is followed by a NOP in that slot,
        #   unless the caller hands it a block whose one instruction goes there instead.
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
          def mthi(rs) = r_type(0x11, rs: rs)
          def mtlo(rs) = r_type(0x13, rs: rs)

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
          def jal(target, &slot) = jump(0x03, target, slot)

          def jr(rs, delay: :nop, &slot)
            r_type(0x08, rs: rs)
            delay_slot(slot) unless delay == :none
          end

          def jalr(rs, delay: :nop, &slot)
            r_type(0x09, rs: rs, rd: :ra)
            delay_slot(slot) unless delay == :none
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
            r_type(function, rs: rs, rt: rt)
          end

          def emit_immediate(op, opcode, rt, rs, number, range)
            raise Error, "#{op} takes #{range.min} to #{range.max}, not #{number}" unless range.cover?(number)

            i_type(opcode, rs: rs, rt: rt, immediate: number, writes: rt)
          end

          def emit_load(op, opcode, rt, distance, base)
            refuse_distance!(op, distance)
            i_type(opcode, rs: base, rt: rt, immediate: distance, writes: rt)
            @loaded = register(rt)
          end

          def emit_store(op, opcode, rt, distance, base)
            refuse_distance!(op, distance)
            i_type(opcode, rs: base, rt: rt, immediate: distance, reads: [rt, base])
          end

          # A branch: +word+ with the two registers it compares (rs, then rt) put in, its distance filled in
          # by the Linker, and its delay slot.
          def emit_branch(word, (rs, rt), target, slot)
            fixup(:branch16, target)
            emit(word | (register(rs) << 21) | (register(rt) << 16), reads: [rs, rt])
            delay_slot(slot)
          end

          def register(name)
            REGISTERS.fetch(name) { raise Error, "the R3000 has no register #{name.inspect}" }
          end

          def refuse_distance!(op, distance)
            raise Error, "#{op} reaches -32768 to 32767 bytes, not #{distance}" unless distance.between?(-0x8000, 0x7FFF)
          end

          def r_type(function, rs: :zero, rt: :zero, rd: :zero, shift: 0)
            emit((register(rs) << 21) | (register(rt) << 16) | (register(rd) << 11) | (shift << 6) | function,
                 reads: [rs, rt])
          end

          def i_type(opcode, rs: :zero, rt: :zero, immediate: 0, writes: nil, reads: [rs])
            reads = [rs] if writes
            emit((opcode << 26) | (register(rs) << 21) | (register(rt) << 16) | (immediate & 0xFFFF), reads: reads)
          end

          def read_hi_lo(function, rd)
            r_type(function, rd: rd)
            @since_hi_lo = 0
          end

          def jump(opcode, target, slot)
            fixup(:jump26, target)
            emit(opcode << 26)
            delay_slot(slot)
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
          end

          # Puts a NOP after a load when the instruction to come reads what it loaded.
          def emit(word, reads: [])
            emit_word(0) if @loaded && reads.any? { |name| name != :zero && register(name) == @loaded }
            emit_word(word)
          end

          def emit_nop_after_load = (emit_word(0) if @loaded)

          def emit_word(word)
            @loaded = nil
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
