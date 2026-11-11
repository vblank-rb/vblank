# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # THE PC'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the 80386 in real mode, written so
        # the lowering reads like the assembly a person would write and never spells out an opcode by hand.
        #
        # REAL MODE is the 8086's way of working, kept so old programs still run: registers are 16 bits, an
        # address is a 16-bit offset into a 64K segment named by a segment register, and the processor
        # reaches 1 megabyte. The 386 added 32-bit registers (EAX, EBX... whose low halves are AX, BX...)
        # and they work in real mode too, through the OPERAND-SIZE PREFIX 66h: put it before an
        # instruction and the instruction works on 32 bits instead of 16. So `add ax, bx` is 01 D8, and
        # `add eax, ebx` is 66 01 D8. That is how a game's 32-bit numbers (IR::Int32) are one instruction
        # each. An address is still 16 bits, so a number is read from `[bx + 4]` and never `[ebx + 4]`.
        #
        # An instruction is an OPCODE and, when it names a register or memory, a MODRM byte: two bits for the
        # mode, three for a register and three for the other register or the way memory is reached.
        #
        #   mod 11   the other operand is a register
        #   mod 00   memory at [base + index], no distance (rm 110 alone is a plain address, [disp16])
        #   mod 01   memory at [base + index + a signed 8-bit distance]
        #   mod 10   memory at [base + index + a 16-bit distance]
        #
        # and in 16-bit addressing rm is 000 [bx+si], 001 [bx+di], 010 [bp+si], 011 [bp+di], 100 [si],
        # 101 [di], 110 [bp] and 111 [bx]. Every number is written low byte first.
        #
        # A JUMP IS ALWAYS THE NEAR FORM with a 16-bit distance (E9, and 0F 8x for a condition): the distance
        # is from the end of the instruction. Short jumps would save a byte and cost a second pass to know
        # which fit, and a game's code is nowhere near the 64K that makes the long form necessary.
        #
        # An X86 writes one run of code (or data) with names for places in it (labels) and holes still to
        # fill (fixups): a jump's distance, and a word that must hold a SEGMENT. DOS loads a program wherever
        # there is room, so a segment number is known only then, and the header lists each such word for DOS
        # to add the load place to (Cartridge::DOSEXE's relocations). #assemble hands back where they are.
        #
        #   asm.mov(:ax, 0x13)                   # mov ax, 13h
        #   asm.add(:eax, mem(:bx, 4))           # add eax, [bx+4]
        #   asm.jne("loop")                      # jne loop
        class X86
          # Raised for an instruction the processor does not have, or an operand that does not fit one: a
          # mistake in the lowering.
          class Error < StandardError; end

          # A place in memory: +base+ and +index+ are register names or nil, +disp+ a number added, +seg+ a
          # segment register to use instead of the usual one (DS, or SS when the base is BP), and +size+ how
          # many bits the place holds (8, 16 or 32), or nil.
          #
          # MEMORY HAS NO SIZE OF ITS OWN: `mov [bx], 1` could store a byte, a word or a doubleword, and the
          # processor is told which by the opcode and the 66h prefix. Where a register is the other operand its
          # size says; where a number is, or nothing (`inc [bx]`), the place must say it, and an instruction
          # with a place of no size and no register is refused rather than guessed.
          Mem = Data.define(:base, :index, :disp, :seg, :size)

          REGISTERS_32 = %i[eax ecx edx ebx esp ebp esi edi].freeze
          REGISTERS_16 = %i[ax cx dx bx sp bp si di].freeze
          REGISTERS_8 = %i[al cl dl bl ah ch dh bh].freeze
          SEGMENTS = %i[es cs ss ds fs gs].freeze
          SEGMENT_PREFIX = { es: 0x26, cs: 0x2E, ss: 0x36, ds: 0x3E, fs: 0x64, gs: 0x65 }.freeze

          # The arithmetic every one of these shares: the opcode of `op r/m, reg` (the `op reg, r/m` form is
          # one more) and the digit that picks it in the group of instructions that take a number (81h, 83h).
          ARITHMETIC = Ractor.make_shareable({ add: [0x01, 0], or: [0x09, 1], adc: [0x11, 2], sbb: [0x19, 3],
                                               and: [0x21, 4], sub: [0x29, 5], xor: [0x31, 6], cmp: [0x39, 7] })

          # The conditions, as the low four bits of a conditional jump's opcode (Intel's manual, Jcc).
          CONDITIONS = { o: 0, no: 1, b: 2, ae: 3, e: 4, ne: 5, be: 6, a: 7, s: 8, ns: 9, p: 10, np: 11,
                         l: 12, ge: 13, le: 14, g: 15 }.freeze

          # The shifts, by the digit that picks them in the group of shift instructions (C1h, D3h).
          SHIFTS = { shl: 4, shr: 5, sar: 7, rol: 0, ror: 1 }.freeze

          # What an assembled run holds: its bytes, and where its words that name a segment are.
          Assembled = Data.define(:bytes, :segment_words)

          def self.mem(base = nil, disp = 0, index: nil, seg: nil, size: nil)
            raise Error, "[#{index}] is not an address: an index needs a base (bx or bp)" if base.nil? && index
            unless base.nil? || ADDRESSING.key?([base, index])
              raise Error, "[#{[base, index].compact.join('+')}] is not an address 16-bit code can name"
            end
            raise Error, "#{size} bits is not a size memory can be read in" unless [nil, 8, 16, 32].include?(size)

            Mem.new(base: base, index: index, disp: disp, seg: seg, size: size)
          end

          def initialize
            @bytes = "".b
            @labels = {}
            @fixups = [] # [at, kind, name]
          end

          def mem(...) = self.class.mem(...)

          # The number of bytes so far: where the next instruction goes.
          def here = @bytes.bytesize

          # Names the next place +name+.
          def label(name)
            raise Error, "the label #{name.inspect} is named twice" if @labels.key?(name)

            @labels[name] = here
          end

          def label?(name) = @labels.key?(name)

          # Where label +name+ is, once placed.
          def offset_of(name) = @labels.fetch(name) { raise Error, "the label #{name.inspect} is not placed" }

          # Plain bytes, for data.
          def bytes(data) = emit(data.b)
          def byte(value) = emit([value].pack("C"))
          def word(value) = emit([value].pack("v"))
          def dword(value) = emit([value].pack("V"))

          # --- moves ---

          # mov destination, source: a register or memory from a register, a number or memory, and a segment
          # register from a 16-bit register or the other way about. Memory from a number takes the place's
          # size (Mem).
          def mov(destination, source)
            return emit_modrm(0x8E, destination, nil, source, size: 16) if segment?(destination)
            return emit_modrm(0x8C, source, nil, destination, size: 16) if segment?(source)

            return move_accumulator(destination, source) if accumulator_with_address?(destination, source)

            case source
            when Integer then move_number(destination, source)
            when Symbol then emit_modrm(opcode_for(source, 0x88, 0x89), source, nil, destination)
            else emit_modrm(opcode_for(destination, 0x8A, 0x8B), destination, nil, source)
            end
          end

          # mov register, SEGMENT name: a 16-bit register loaded with a segment number that is not known until
          # DOS loads the program (the header relocates the word).
          def mov_segment(register, name)
            emit([0xB8 + REGISTERS_16.index(register)].pack("C"))
            fixup(:segment, name)
            word(0)
          end

          # mov register, OFFSET label: a 16-bit register loaded with where +label+ is in the code segment,
          # for a routine handed over by its address (an interrupt's).
          def mov_offset(register, label)
            emit([0xB8 + REGISTERS_16.index(register)].pack("C"))
            fixup(:offset, label)
            word(0)
          end

          def lea(register, memory) = emit_modrm(0x8D, register, nil, memory)

          def movzx(destination, source)
            emit_modrm([0x0F, byte_size?(source) ? 0xB6 : 0xB7], destination, nil, source, size: size_of(destination))
          end

          def movsx(destination, source)
            emit_modrm([0x0F, byte_size?(source) ? 0xBE : 0xBF], destination, nil, source, size: size_of(destination))
          end

          # xchg: with AX or EAX one byte names the other register (90h + its number).
          def xchg(first, second)
            first, second = second, first if second == :ax || second == :eax
            if (first == :ax && REGISTERS_16.include?(second)) || (first == :eax && REGISTERS_32.include?(second))
              emit([0x66].pack("C")) if first == :eax
              return emit([0x90 + field_of(second)].pack("C"))
            end

            emit_modrm(opcode_for(first, 0x86, 0x87), first, nil, second)
          end

          def push(register)
            return emit([0x50 + REGISTERS_16.index(register)].pack("C")) if REGISTERS_16.include?(register)
            return emit([0x66, 0x50 + REGISTERS_32.index(register)].pack("C*")) if REGISTERS_32.include?(register)

            emit([{ es: 0x06, cs: 0x0E, ss: 0x16, ds: 0x1E }.fetch(register)].pack("C"))
          end

          def pop(register)
            return emit([0x58 + REGISTERS_16.index(register)].pack("C")) if REGISTERS_16.include?(register)
            return emit([0x66, 0x58 + REGISTERS_32.index(register)].pack("C*")) if REGISTERS_32.include?(register)

            emit([{ es: 0x07, ss: 0x17, ds: 0x1F }.fetch(register)].pack("C"))
          end

          # --- arithmetic ---

          # Must stay shareable: a method made from a plain block cannot be called from a Ractor other
          # than the one that made it, and tests build games in Ractors. So each block below is made
          # shareable before it becomes a method (it captures only the frozen name and numbers).
          def self.instruction(name, &body)
            define_method(name, &Ractor.make_shareable(body))
          end
          private_class_method :instruction

          ARITHMETIC.each_key do |name|
            instruction(name) { |destination, source| arithmetic(name, destination, source) }
          end

          def test(destination, source)
            return emit_modrm(opcode_for(source, 0x84, 0x85), source, nil, destination) if source.is_a?(Symbol)

            emit_modrm(opcode_for(destination, 0xF6, 0xF7), nil, 0, destination)
            emit_number(source, size_of(destination))
          end

          # inc and dec of a 16-bit or 32-bit register are one byte (40h + its number, 48h + for dec).
          def inc(operand) = count_by_one(operand, 0x40, 0)
          def dec(operand) = count_by_one(operand, 0x48, 1)
          def not(operand) = emit_modrm(opcode_for(operand, 0xF6, 0xF7), nil, 2, operand)
          def neg(operand) = emit_modrm(opcode_for(operand, 0xF6, 0xF7), nil, 3, operand)
          def mul(operand) = emit_modrm(opcode_for(operand, 0xF6, 0xF7), nil, 4, operand)
          def div(operand) = emit_modrm(opcode_for(operand, 0xF6, 0xF7), nil, 6, operand)
          def idiv(operand) = emit_modrm(opcode_for(operand, 0xF6, 0xF7), nil, 7, operand)

          # imul destination, source: the low half of the signed product, which is the 32-bit wrapping product.
          def imul(destination, source) = emit_modrm([0x0F, 0xAF], destination, nil, source)

          # Sign-extends: CDQ fills EDX with EAX's sign (66 99), CWD does the same from AX into DX.
          def cdq = emit([0x66, 0x99].pack("C*"))
          def cwd = emit([0x99].pack("C"))

          # shl, shr, sar, rol, ror by a count in CL, or a number.
          SHIFTS.each do |name, digit|
            instruction(name) do |operand, count|
              if count == :cl
                emit_modrm(opcode_for(operand, 0xD2, 0xD3), nil, digit, operand)
              else
                emit_modrm(opcode_for(operand, 0xC0, 0xC1), nil, digit, operand)
                byte(count)
              end
            end
          end

          # setcc register: 1 in the byte register when the condition holds, else 0.
          CONDITIONS.each do |name, code|
            instruction(:"set#{name}") { |register| emit_modrm([0x0F, 0x90 + code], nil, 0, register, size: 8) }
            instruction(:"j#{name}") { |label| jump_near([0x0F, 0x80 + code], label) }
          end

          # --- flow ---

          def jmp(label) = jump_near([0xE9], label)
          def call(label) = jump_near([0xE8], label)
          # call far [memory]: the routine whose offset and segment are the two words at +memory+.
          def call_far(memory) = emit_modrm(0xFF, nil, 3, memory, size: 16)
          def ret = emit([0xC3].pack("C"))
          def iret = emit([0xCF].pack("C"))
          def int(number) = emit([0xCD, number].pack("C*"))
          def hlt = emit([0xF4].pack("C"))
          def nop = emit([0x90].pack("C"))
          def cli = emit([0xFA].pack("C"))
          def sti = emit([0xFB].pack("C"))
          def cld = emit([0xFC].pack("C"))
          def pushf = emit([0x9C].pack("C"))
          def popf = emit([0x9D].pack("C"))

          # --- ports and strings ---

          # in al, dx / in ax, dx and out dx, al / out dx, ax: the port number is always in DX.
          def in_from_dx(register) = emit([register == :al ? 0xEC : 0xED].pack("C"))
          def out_to_dx(register) = emit([register == :al ? 0xEE : 0xEF].pack("C"))
          def in_byte(port) = emit([0xE4, port].pack("C*"))
          def out_byte(port) = emit([0xE6, port].pack("C*"))

          # The string instructions, each repeated by CX with +rep+: stos stores AL, AX or EAX at ES:DI, movs
          # copies from DS:SI to ES:DI, lods loads from DS:SI. +size+ is 8, 16 or 32.
          def stos(size, rep: false) = string_instruction(0xAA, size, rep)
          def movs(size, rep: false) = string_instruction(0xA4, size, rep)
          def lods(size, rep: false) = string_instruction(0xAC, size, rep)

          # The finished run: every jump's distance filled, and where each word that names a segment is.
          # +segments+ is the segment numbers to put in those words (the header adds the load place to each),
          # by name.
          def assemble(segments = {})
            bytes = @bytes.dup
            words = []
            @fixups.each do |at, kind, name|
              case kind
              when :near
                bytes[at, 2] = [offset_of(name) - (at + 2)].pack("s<")
              when :offset
                bytes[at, 2] = [offset_of(name)].pack("v")
              when :segment
                bytes[at, 2] = [segments.fetch(name) { raise Error, "no segment is named #{name.inspect}" }].pack("v")
                words << at
              end
            end
            Assembled.new(bytes: bytes, segment_words: words)
          end

          private

          def emit(data)
            data = data.pack("C*") if data.is_a?(Array)
            @bytes << data
            self
          end

          def fixup(kind, name) = @fixups << [here, kind, name]

          def jump_near(opcode, label)
            emit(opcode.pack("C*"))
            fixup(:near, label)
            word(0)
          end

          def segment?(operand) = SEGMENTS.include?(operand)
          def byte_size?(operand) = size_of(operand) == 8

          # A register's size, or a place's (Mem): one that says none is refused, since the instruction would
          # be a guess.
          def size_of(operand)
            return memory_size(operand) if operand.is_a?(Mem)
            return 32 if REGISTERS_32.include?(operand)
            return 8 if REGISTERS_8.include?(operand)

            16
          end

          # A register and a place of another size: `mov [a 32-bit word], ax` writes half of it. A place of no
          # size takes the register's.
          def refuse_size_mismatch!(register, operand)
            return unless register.is_a?(Symbol) && operand.is_a?(Mem) && operand.size
            return if size_of(register) == operand.size

            raise Error, "#{register} is #{size_of(register)} bits and #{operand.inspect} is #{operand.size}"
          end

          def memory_size(memory)
            memory.size || raise(Error, "#{memory.inspect} has no size, and nothing else here says one: give it size:")
          end

          # +byte_opcode+ for an 8-bit operand, +word_opcode+ for the others.
          def opcode_for(operand, byte_opcode, word_opcode) = byte_size?(operand) ? byte_opcode : word_opcode

          # mov register, number is one opcode with the register in it; mov [memory], number is C6h or C7h and
          # a modrm byte, in the place's size.
          def move_number(destination, number)
            size = size_of(destination)
            if destination.is_a?(Mem)
              emit_modrm(size == 8 ? 0xC6 : 0xC7, nil, 0, destination, size: size)
            else
              emit([0x66].pack("C")) if size == 32
              emit([size == 8 ? 0xB0 + REGISTERS_8.index(destination) : 0xB8 + field_of(destination)].pack("C"))
            end
            emit_number(number, size)
          end

          # A number as +size+ bits, low byte first: a signed or an unsigned one that fits.
          def emit_number(number, size)
            raise Error, "#{number} does not fit #{size} bits" unless number.between?(-(1 << (size - 1)), (1 << size) - 1)

            emit([number & ((1 << size) - 1)].pack({ 8 => "C", 16 => "v", 32 => "V" }.fetch(size)))
          end

          # arithmetic with a register, memory or number on the right. A number must fit the destination's size
          # (signed or unsigned); one that fits a signed byte takes the short form (83h), sign-extended.
          def arithmetic(name, destination, source)
            opcode, digit = ARITHMETIC.fetch(name)
            if source.is_a?(Integer)
              size = size_of(destination)
              short = size != 8 && source.between?(-128, 127)
              return arithmetic_with_accumulator(digit, destination, source, size) if ACCUMULATORS.include?(destination) && !short

              emit_modrm(size == 8 ? 0x80 : (short ? 0x83 : 0x81), nil, digit, destination, size: size)
              emit_number(source, short ? 8 : size)
            elsif source.is_a?(Symbol)
              emit_modrm(opcode_for(source, opcode - 1, opcode), source, nil, destination)
            else
              emit_modrm(opcode_for(destination, opcode + 1, opcode + 2), destination, nil, source)
            end
          end

          # add, sub and the rest on AL, AX or EAX with a number the short form can't hold: one opcode (digit * 8
          # + 4 for a byte, + 5 for the others) then the number.
          def arithmetic_with_accumulator(digit, register, number, size)
            emit([0x66].pack("C")) if size == 32
            emit([(digit * 8) + (size == 8 ? 4 : 5)].pack("C"))
            emit_number(number, size)
          end

          def count_by_one(operand, short_base, digit)
            if operand.is_a?(Symbol) && !byte_size?(operand)
              emit([0x66].pack("C")) if size_of(operand) == 32
              return emit([short_base + field_of(operand)].pack("C"))
            end

            emit_modrm(opcode_for(operand, 0xFE, 0xFF), nil, digit, operand)
          end

          ACCUMULATORS = %i[al ax eax].freeze

          def accumulator_with_address?(destination, source)
            (ACCUMULATORS.include?(destination) && direct?(source)) || (ACCUMULATORS.include?(source) && direct?(destination))
          end

          def direct?(operand) = operand.is_a?(Mem) && operand.base.nil? && operand.seg.nil?

          # mov al/ax/eax from or to a plain address: the opcode carries the register, and the address follows.
          def move_accumulator(destination, source)
            into = ACCUMULATORS.include?(destination)
            register = into ? destination : source
            memory = into ? source : destination
            refuse_size_mismatch!(register, memory)
            emit([0x66].pack("C")) if register == :eax
            emit([(into ? 0xA0 : 0xA2) + (register == :al ? 0 : 1)].pack("C"))
            word(memory.disp)
          end

          def string_instruction(base, size, rep)
            emit([0x66].pack("C")) if size == 32
            emit([0xF3].pack("C")) if rep
            emit([size == 8 ? base : base + 1].pack("C"))
          end

          # One instruction with a modrm byte. +opcode+ is a byte or bytes; +register+ the register field (a
          # register name), or +digit+ (a number) when the opcode needs one; +operand+ the register or memory
          # the other field names. The operand-size prefix and any segment override come first.
          def emit_modrm(opcode, register, digit, operand, size: nil)
            refuse_size_mismatch!(register, operand) unless size
            size ||= size_of(register || operand)
            emit([SEGMENT_PREFIX.fetch(operand.seg)].pack("C")) if operand.is_a?(Mem) && operand.seg
            emit([0x66].pack("C")) if size == 32
            emit(Array(opcode).pack("C*"))
            field = digit || field_of(register)
            if operand.is_a?(Mem)
              emit_memory(field, operand)
            else
              emit([0xC0 | (field << 3) | field_of(operand)].pack("C"))
            end
          end

          def field_of(register)
            return REGISTERS_32.index(register) if REGISTERS_32.include?(register)
            return REGISTERS_16.index(register) if REGISTERS_16.include?(register)
            return REGISTERS_8.index(register) if REGISTERS_8.include?(register)
            return SEGMENTS.index(register) if SEGMENTS.include?(register)

            raise Error, "#{register.inspect} is not a register"
          end

          # The rm values of 16-bit addressing, by [base, index].
          ADDRESSING = Ractor.make_shareable({ %i[bx si] => 0, %i[bx di] => 1, %i[bp si] => 2, %i[bp di] => 3,
                                               [:si, nil] => 4, [:di, nil] => 5, [:bp, nil] => 6, [:bx, nil] => 7 })

          def emit_memory(field, memory)
            return emit([(field << 3) | 6].pack("C")) && word(memory.disp) if memory.base.nil?

            rm = ADDRESSING.fetch([memory.base, memory.index]) { raise Error, "[#{memory.base}+#{memory.index}] is not an address" }
            disp = memory.disp
            if disp.zero? && rm != 6
              emit([(field << 3) | rm].pack("C"))
            elsif disp.between?(-128, 127)
              emit([0x40 | (field << 3) | rm, disp & 0xFF].pack("C*"))
            else
              emit([0x80 | (field << 3) | rm].pack("C"))
              emit([disp].pack("s<"))
            end
          end
        end
      end
    end
  end
end
