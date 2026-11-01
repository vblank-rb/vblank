# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # THE GENESIS'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the Motorola 68000, written
        # so the lowering reads like the assembly a person would write and never spells out an opcode
        # by hand.
        #
        # The 68000 is a 32-bit processor with a 16-bit data path. It has eight data registers, D0 to
        # D7, which hold numbers and take every sum, and eight address registers, A0 to A7, which hold
        # places in memory (A7 is the stack's pointer). Every one is 32 bits wide, and most
        # instructions work on a byte, a word (16 bits) or a long word (32 bits) of one, as the name's
        # last letter says: `move.l d1,d0` copies all 32 bits, `move.w` the low 16. A game's number is
        # 32 bits, so the lowering uses the long form almost everywhere and a sum is one instruction.
        #
        # There is no mode to follow, unlike a 65816's: the size is in the instruction, so this
        # assembler is told it each time. It is big-endian: a number is written high byte first. Every
        # instruction is a whole number of 16-bit words, so every instruction starts at an even
        # address. A word or a long word of data must be at an even address too, or the 68000 stops
        # with an address error; the assembler pads each section to an even length so a section
        # placed after another still starts on one.
        #
        # An instruction names where its numbers are with an EFFECTIVE ADDRESS, six bits: three for how
        # to find it and three for which register. The first word of the instruction holds them, and
        # whatever the way needs more (a number, a distance, a place) follows as more words:
        #
        #   d(0)  a(0)                 D0, A0: the register itself
        #   ind(0)                     (A0): the memory A0 points at
        #   post(0)  pre(0)            (A0)+ and -(A0): the same, then A0 moves on, or first moves back
        #   disp(5, 8)                 8(A5): the memory 8 bytes past where A5 points (±32K)
        #   idx(0, 4, 1)               4(A0,D1.l): A0 plus D1 plus 4 (the byte distance is ±128)
        #   abs_w(0x8000)              (-$8000).w: a 16-bit place, taken as signed, so it reaches the
        #                              first 32K of the address space and the last (work RAM's top half)
        #   abs_l(0xC00004)            ($C00004).l: a whole 24-bit place; or a label's, filled in later
        #   pc_rel("table")            table(PC): the place of a label near the instruction (±32K)
        #   imm(5)  imm("table")       #5, or the address of a label as a number
        #
        # A label is a String, so it can never be taken for a number. A branch to one is always the
        # sixteen-bit form (±32K from the branch), and a call or a jump to another section is `jsr
        # abs_l("name")`, which reaches any place.
        #
        # An Assembler writes one Section: a run of bytes with names for places in it (labels) and holes
        # still to fill (fixups) where an instruction names a place that may be in another section.
        # The Linker puts the sections in the cartridge and fills the holes.
        #
        #   asm.move(:l, disp(5, 8), d(0))     # move.l 8(a5),d0
        #   asm.add(:l, d(1), d(0))            # add.l d1,d0
        #   asm.branch(:ne, "loop")            # bne loop
        class M68000
          Operand = Data.define(:mode, :reg, :value, :plus, :index, :index_size)

          # Raised for an instruction the processor does not have — a mistake in the lowering.
          class Error < StandardError; end

          # A place named in an instruction, filled in once everything is placed (Sections::Fixup). Its
          # +kind+ here is :abs32 (the whole address, four bytes), :abs16 (an address that fits a signed
          # sixteen-bit place) or :rel16 (a distance from the word the hole is in, one signed word).
          Fixup = Sections::Fixup
          Section = Sections::Section
          Holding = Sections::Holding

          # Where the size goes in an instruction: the two bits most take, and a MOVE's own.
          SIZES = { b: 0, w: 1, l: 2 }.freeze
          MOVE_SIZES = { b: 1, w: 3, l: 2 }.freeze

          # The condition a branch, a set or a decrement tests: the four bits it is encoded as.
          CONDITIONS = Ractor.make_shareable({
            t: 0, f: 1, hi: 2, ls: 3, cc: 4, hs: 4, cs: 5, lo: 5, ne: 6, eq: 7, vc: 8, vs: 9, pl: 10, mi: 11,
            ge: 12, lt: 13, gt: 14, le: 15
          })

          # The instructions of the shape `op <ea>,Dn` or `op Dn,<ea>`: the opcode of the form that
          # leaves the sum in Dn (a size's bits go in at 7-6), and its immediate form's.
          ALU = Ractor.make_shareable({
            add: { base: 0xD000, immediate: 0x0600 }, sub: { base: 0x9000, immediate: 0x0400 },
            and: { base: 0xC000, immediate: 0x0200 }, or: { base: 0x8000, immediate: 0x0000 }
          })

          # What each shift does, as the two bits of its type.
          SHIFTS = { as: 0, ls: 1, rox: 2, ro: 3 }.freeze

          BIT_OPERATIONS = { btst: 0, bchg: 1, bclr: 2, bset: 3 }.freeze

          # A long word to be filled in later, written as noughts.
          ZERO_LONG = "\0\0\0\0".b.freeze

          # The one-word instructions with nothing to say.
          SINGLES = { nop: 0x4E71, rts: 0x4E75, rte: 0x4E73, reset: 0x4E70, illegal: 0x4AFC }.freeze

          attr_reader :bytes

          def initialize(name, home: :any, holds: nil)
            @name = name
            @home = home
            @holds = holds
            @bytes = +"".b
            @labels = {}
            @fixups = []
          end

          # --- operands ---

          def d(register) = Operand.new(:dn, check_register(register), nil, 0, nil, nil)
          def a(register) = Operand.new(:an, check_register(register), nil, 0, nil, nil)
          def ind(register) = Operand.new(:ind, check_register(register), nil, 0, nil, nil)
          def post(register) = Operand.new(:post, check_register(register), nil, 0, nil, nil)
          def pre(register) = Operand.new(:pre, check_register(register), nil, 0, nil, nil)
          def disp(register, distance) = Operand.new(:disp, check_register(register), distance, 0, nil, nil)
          def abs_w(value, plus = 0) = Operand.new(:abs_w, nil, value, plus, nil, nil)
          def abs_l(value, plus = 0) = Operand.new(:abs_l, nil, value, plus, nil, nil)
          def pc_rel(label, plus = 0) = Operand.new(:pc, nil, label, plus, nil, nil)
          def imm(value, plus = 0) = Operand.new(:imm, nil, value, plus, nil, nil)

          # The memory at A(register) + D(index) + distance; the index is the long or the word of D.
          def idx(register, distance, index, size = :l)
            raise Error, "an indexed distance is one byte, not #{distance}" unless distance.between?(-128, 127)

            Operand.new(:index, check_register(register), distance, 0, check_register(index), size)
          end

          # The stack's pointer, which is A7.
          SP = 7

          # --- the section ---

          # Where the next byte goes, counted from the start of this section.
          def here = @bytes.bytesize

          # Names the next byte. A name is the whole program's: two sections cannot share one.
          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            name
          end

          # The section, padded to a whole number of words so the one placed after it starts at an
          # even address.
          def section
            bytes = @bytes.dup
            bytes << "\0" if bytes.bytesize.odd?
            Section.new(name: @name, bytes: bytes.freeze, labels: @labels.dup.freeze, fixups: @fixups.dup.freeze,
                        home: @home, holds: @holds)
          end

          # --- data ---

          def data_bytes(*values) = values.flatten.each { |value| @bytes << [byte_of(value)].pack("C") }

          # 16-bit words, high byte first.
          def data_words(*values) = values.flatten.each { |value| @bytes << [value & 0xFFFF].pack("n") }

          # 32-bit long words, high byte first; a String is the address of that label.
          def data_longs(*values)
            values.flatten.each do |value|
              if value.is_a?(String)
                fixup(:abs32, value)
                @bytes << ZERO_LONG
              else
                @bytes << [value & 0xFFFF_FFFF].pack("N")
              end
            end
          end

          # --- moving numbers ---

          def move(size, source, destination)
            refuse!("MOVE to an address register: use MOVEA") if destination.mode == :an
            refuse!("MOVE to an immediate number") if destination.mode == :imm
            word((MOVE_SIZES.fetch(size) << 12) | field(destination, 6, 9) | field(source, 3, 0))
            extension(source, size)
            extension(destination, size)
          end

          def movea(size, source, destination)
            raise Error, "MOVEA takes a word or a long, not #{size}" if size == :b
            raise Error, "MOVEA goes to an address register" unless destination.mode == :an

            word((MOVE_SIZES.fetch(size) << 12) | (destination.reg << 9) | (1 << 6) | field(source, 3, 0))
            extension(source, size)
          end

          # MOVEQ: a number from -128 to 127, made 32 bits, into a data register.
          def moveq(value, register)
            raise Error, "MOVEQ takes -128 to 127, not #{value}" unless value.between?(-128, 127)

            word(0x7000 | (register.reg << 9) | (value & 0xFF))
          end

          def lea(source, register)
            word(0x41C0 | (register.reg << 9) | field(source, 3, 0))
            extension(source, :l)
          end

          def pea(source)
            word(0x4840 | field(source, 3, 0))
            extension(source, :l)
          end

          # MOVEM: the registers named (:d0 to :d7, :a0 to :a7) to or from memory. A push writes them
          # below the address register +via+ (the stack by default) and moves it down, and a pop reads
          # them back from where it points and moves it up.
          def movem_push(size, *registers, via: SP)
            word(0x4880 | movem_size(size) | field(pre(via), 3, 0))
            word(movem_mask(registers, reversed: true))
          end

          def movem_pop(size, *registers, via: SP)
            word(0x4C80 | movem_size(size) | field(post(via), 3, 0))
            word(movem_mask(registers, reversed: false))
          end

          # --- sums ---

          ALU.each_key do |name|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(size, source, destination) = alu(:#{name}, size, source, destination)
            RUBY
          end

          def eor(size, source, destination)
            if source.mode == :imm
              emit_immediate_form(0x0A00, size, source, destination)
            else
              raise Error, "EOR takes a data register as its source" unless source.mode == :dn

              word(0xB000 | (source.reg << 9) | ((4 + SIZES.fetch(size)) << 6) | field(destination, 3, 0))
              extension(destination, size)
            end
          end

          def cmp(size, source, destination)
            return emit_immediate_form(0x0C00, size, source, destination) if source.mode == :imm && destination.mode != :an

            if destination.mode == :an
              word(0xB0C0 | (destination.reg << 9) | (size == :l ? 0x100 : 0) | field(source, 3, 0))
            else
              raise Error, "CMP compares into a data register" unless destination.mode == :dn

              word(0xB000 | (destination.reg << 9) | (SIZES.fetch(size) << 6) | field(source, 3, 0))
            end
            extension(source, size)
          end

          # ADDQ and SUBQ: a number from 1 to 8 added to or taken from the destination, in one word.
          def addq(size, value, destination) = quick(0x5000, size, value, destination)
          def subq(size, value, destination) = quick(0x5100, size, value, destination)

          { neg: 0x4400, not: 0x4600, clr: 0x4200, tst: 0x4A00 }.each do |name, base|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(size, destination)
                word(#{base} | (SIZES.fetch(size) << 6) | field(destination, 3, 0))
                extension(destination, size)
              end
            RUBY
          end

          # EXT: the low byte of a data register made a word (+size+ :w), or its low word made a long (:l).
          def ext(size, register) = word((size == :l ? 0x48C0 : 0x4880) | register.reg)

          # SWAP: the two halves of a data register exchanged.
          def swap(register) = word(0x4840 | register.reg)

          def mulu(source, register) = word_multiply(0xC0C0, source, register)
          def muls(source, register) = word_multiply(0xC1C0, source, register)
          def divu(source, register) = word_multiply(0x80C0, source, register)
          def divs(source, register) = word_multiply(0x81C0, source, register)

          # --- shifts ---
          #
          # A shift of a data register by a count from 1 to 8, or by the low six bits of another
          # data register. Written out as source: a method made from a block carries the block with it,
          # and Ruby will not let another Ractor call one.

          { asl: [:as, true], asr: [:as, false], lsl: [:ls, true], lsr: [:ls, false],
            rol: [:ro, true], ror: [:ro, false], roxl: [:rox, true], roxr: [:rox, false] }.each do |name, (type, left)|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(size, count, register) = shift(:#{type}, #{left}, size, count, register)
            RUBY
          end

          # --- bits ---

          BIT_OPERATIONS.each_key do |name|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(bit, destination) = bit_operation(:#{name}, bit, destination)
            RUBY
          end

          # --- jumps and branches ---

          def jmp(target)
            word(0x4EC0 | field(target, 3, 0))
            extension(target, :l)
          end

          def jsr(target)
            word(0x4E80 | field(target, 3, 0))
            extension(target, :l)
          end

          SINGLES.each { |name, opcode| class_eval("def #{name} = word(#{opcode})", __FILE__, __LINE__) }

          # STOP: wait for an interrupt, with the status register set to +status+ first.
          def stop(status)
            word(0x4E72)
            word(status)
          end

          def trap(number)
            raise Error, "TRAP takes 0 to 15, not #{number}" unless number.between?(0, 15)

            word(0x4E40 | number)
          end

          # Branch to +target+ when +condition+ holds (CONDITIONS; :t is always): a distance of 16
          # bits from the instruction.
          def branch(condition, target)
            word(0x6000 | (condition_bits(condition) << 8))
            fixup(:rel16, target)
            word(0)
          end

          def bra(target) = branch(:t, target)

          def bsr(target)
            word(0x6100)
            fixup(:rel16, target)
            word(0)
          end

          # A branch over the next +bytes+ bytes, an even number from 2 to 254, when +condition+
          # holds: one word, for a skip over code whose length is known.
          def branch_over(condition, bytes)
            raise Error, "a short branch skips an even 2 to 254 bytes, not #{bytes}" unless bytes.even? && bytes.between?(2, 254)

            word(0x6000 | (condition_bits(condition) << 8) | bytes)
          end

          # DBRA: take one off the low word of a data register, and branch unless that made it -1. A
          # loop of N turns counts N-1 down to -1.
          def dbra(register, target)
            word(0x51C8 | register.reg)
            fixup(:rel16, target)
            word(0)
          end

          # Scc: the low byte of the destination made $FF when +condition+ holds and $00 when it does not.
          def scc(condition, destination)
            word(0x50C0 | (condition_bits(condition) << 8) | field(destination, 3, 0))
            extension(destination, :b)
          end

          # --- the status register ---

          def move_from_sr(destination)
            word(0x40C0 | field(destination, 3, 0))
            extension(destination, :w)
          end

          def move_to_sr(source)
            word(0x46C0 | field(source, 3, 0))
            extension(source, :w)
          end

          def ori_to_sr(value)
            word(0x007C)
            word(value)
          end

          def andi_to_sr(value)
            word(0x027C)
            word(value)
          end

          private

          def check_register(register)
            raise Error, "a register is 0 to 7, not #{register.inspect}" unless register.is_a?(Integer) && register.between?(0, 7)

            register
          end

          def refuse!(words) = raise(Error, "the 68000 has no #{words}")

          def condition_bits(condition) = CONDITIONS.fetch(condition) { raise Error, "no condition named #{condition.inspect}" }

          def byte_of(value)
            raise Error, "#{value} does not fit in a byte" unless value.between?(-128, 255)

            value & 0xFF
          end

          def word(value) = @bytes << [value & 0xFFFF].pack("n")

          def fixup(kind, label, plus = 0) = @fixups << Fixup.new(offset: here, kind: kind, label: label.to_s, plus: plus)

          # The six bits that say how to find an operand: the mode and the register, in the order the
          # instruction wants them. A MOVE's destination has them the other way round (register first).
          def field(operand, mode_at, register_at)
            mode, register = mode_and_register(operand)
            (mode << mode_at) | (register << register_at)
          end

          def mode_and_register(operand)
            case operand.mode
            when :dn then [0, operand.reg]
            when :an then [1, operand.reg]
            when :ind then [2, operand.reg]
            when :post then [3, operand.reg]
            when :pre then [4, operand.reg]
            when :disp then [5, operand.reg]
            when :index then [6, operand.reg]
            when :abs_w then [7, 0]
            when :abs_l then [7, 1]
            when :pc then [7, 2]
            when :imm then [7, 4]
            else raise Error, "no way to reach #{operand.mode}"
            end
          end

          # What an operand's way of finding needs after the first word. A MOVE's destination field is
          # (register, mode) and the others' (mode, register): the two differ in the order of bits, and
          # #field takes where each goes.
          def extension(operand, size)
            case operand.mode
            when :disp then word(signed16(operand.value, "a distance"))
            when :index
              word(((operand.index) << 12) | ((operand.index_size == :l ? 1 : 0) << 11) | (operand.value & 0xFF))
            when :abs_w then emit_word_address(operand)
            when :abs_l then emit_long_address(operand)
            when :pc then pc_extension(operand)
            when :imm then emit_immediate(operand, size)
            end
          end

          def signed16(value, what)
            raise Error, "#{what} of #{value} does not fit in 16 bits" unless value.between?(-32_768, 32_767)

            value
          end

          def emit_word_address(operand)
            if operand.value.is_a?(String)
              fixup(:abs16, operand.value, operand.plus)
              return word(0)
            end
            value = operand.value + operand.plus
            raise Error, "#{format('$%X', value)} is not reached by a 16-bit address" unless
              value.between?(0, 0x7FFF) || value.between?(0xFF8000, 0xFFFFFF)

            word(value)
          end

          def emit_long_address(operand)
            if operand.value.is_a?(String)
              fixup(:abs32, operand.value, operand.plus)
              return @bytes << ZERO_LONG
            end
            @bytes << [(operand.value + operand.plus) & 0xFFFF_FFFF].pack("N")
          end

          def pc_extension(operand)
            fixup(:rel16, operand.value, operand.plus)
            word(0)
          end

          def emit_immediate(operand, size)
            if operand.value.is_a?(String)
              raise Error, "the address of a label is a long number" unless size == :l

              fixup(:abs32, operand.value, operand.plus)
              return @bytes << ZERO_LONG
            end
            value = operand.value + operand.plus
            case size
            when :b then word(byte_of(value))
            when :w then word(value)
            when :l then @bytes << [value & 0xFFFF_FFFF].pack("N")
            end
          end

          def alu(name, size, source, destination)
            form = ALU.fetch(name)
            if source.mode == :imm && destination.mode != :an
              return emit_immediate_form(form[:immediate], size, source, destination)
            end

            if destination.mode == :an
              raise Error, "#{name.upcase} to an address register is a word or a long" if size == :b
              raise Error, "AND and OR have no address register form" unless %i[add sub].include?(name)

              word(form[:base] | (destination.reg << 9) | ((size == :l ? 7 : 3) << 6) | field(source, 3, 0))
              extension(source, size)
            elsif destination.mode == :dn
              word(form[:base] | (destination.reg << 9) | (SIZES.fetch(size) << 6) | field(source, 3, 0))
              extension(source, size)
            else
              raise Error, "#{name.upcase} into memory takes a data register as its source" unless source.mode == :dn

              word(form[:base] | (source.reg << 9) | ((4 + SIZES.fetch(size)) << 6) | field(destination, 3, 0))
              extension(destination, size)
            end
          end

          # ADDI, SUBI, ANDI, ORI, EORI, CMPI: the number follows the first word, then the destination's
          # own words.
          def emit_immediate_form(base, size, source, destination)
            raise Error, "an immediate form goes to a register or memory, not #{destination.mode}" if %i[an imm].include?(destination.mode)

            word(base | (SIZES.fetch(size) << 6) | field(destination, 3, 0))
            extension(source, size)
            extension(destination, size)
          end

          def quick(base, size, value, destination)
            raise Error, "ADDQ and SUBQ take 1 to 8, not #{value}" unless value.between?(1, 8)
            raise Error, "ADDQ and SUBQ to an address register are a word or a long" if destination.mode == :an && size == :b

            word(base | ((value & 7) << 9) | (SIZES.fetch(size) << 6) | field(destination, 3, 0))
            extension(destination, size)
          end

          def word_multiply(base, source, register)
            word(base | (register.reg << 9) | field(source, 3, 0))
            extension(source, :w)
          end

          def shift(type, left, size, count, register)
            amount = if count.is_a?(Integer)
                       raise Error, "a shift by a number is 1 to 8, not #{count}" unless count.between?(1, 8)

                       (count & 7) << 9
                     else
                       raise Error, "a shift by a register uses a data register" unless count.mode == :dn

                       (count.reg << 9) | 0x20
                     end
            word(0xE000 | amount | ((left ? 1 : 0) << 8) | (SIZES.fetch(size) << 6) | (SHIFTS.fetch(type) << 3) | register.reg)
          end

          def bit_operation(name, bit, destination)
            type = BIT_OPERATIONS.fetch(name) << 6
            if bit.is_a?(Integer)
              word(0x0800 | type | field(destination, 3, 0))
              word(bit)
            else
              word(0x0100 | (bit.reg << 9) | type | field(destination, 3, 0))
            end
            extension(destination, :b)
          end

          def movem_size(size) = size == :l ? 0x40 : 0

          # The registers a MOVEM names as its mask word: bit 0 is D0 and bit 15 A7 — or the other way
          # round when the registers are written below the stack (a push), where the first register
          # written is the last.
          def movem_mask(registers, reversed:)
            registers.sum do |name|
              bit = register_bit(name)
              1 << (reversed ? 15 - bit : bit)
            end
          end

          def register_bit(name)
            kind, number = name.to_s.match(/\A([ad])([0-7])\z/)&.captures
            raise Error, "#{name.inspect} is not a register (d0 to d7, a0 to a7)" unless kind

            number.to_i + (kind == "a" ? 8 : 0)
          end
        end
      end
    end
  end
end
