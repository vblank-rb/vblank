# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE SUPER NINTENDO'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the 65816
        # (the WDC W65C816, the Ricoh 5A22 inside the console runs it), written so the lowering
        # reads like the assembly a person would write and never spells out an opcode by hand.
        #
        # The 65816 is the 6502 grown to 16 bits. It has three registers a program works with: A,
        # the accumulator every sum goes through, and X and Y, which count and index. Each is 8
        # or 16 bits wide, as two flags set: M for A and X for X and Y. REP clears flags and SEP
        # sets them, so `rep 0x30` makes all three 16 bits wide and `sep 0x20` makes A 8 bits.
        # How wide A is decides how many bytes an instruction's number takes (LDA #5 is two bytes
        # with an 8-bit A and three with a 16-bit one), so the assembler follows REP and SEP as it
        # writes, and `widths` sets what they are at a label code jumps to from elsewhere.
        #
        # Memory is reached with a 24-bit address: a bank (the top byte) and 64K inside it. An
        # instruction can name all 24 bits (long), 16 of them in the data bank (absolute), or 8 of
        # them on the direct page (a 256-byte window the lowering keeps its working numbers in).
        # There is no multiply or divide instruction: the console has small multiply and divide
        # units of its own, and the runtime uses them (Runtime::Int32).
        #
        # An Assembler writes one Section: a run of bytes with names for places in it (labels) and
        # holes still to fill (fixups) where an instruction names a place that may be in another
        # section. The Linker puts the sections in the cartridge and fills the holes. A section is
        # always placed whole inside one bank of the cartridge, so a branch or a JMP inside it
        # never has to leave the bank, which the processor cannot do without a long jump.
        #
        # How operands are written (each is an Operand, made by the helpers below):
        #
        #   5, -1, imm(5)                    a number: #5
        #   imm("table")                     the low 16 bits of where "table" is: #<table
        #   bank_of("table")                 the bank "table" is in: #^table
        #   direct(0x10)  direct_x(0x10)     $10, $10,X  on the direct page
        #   abs(0x0100)  abs_x  abs_y        $0100, $0100,X  in the data bank
        #   long("table")  long_x("table")   the 24-bit address of "table", and that plus X
        #   ind(0x10)  ind_y  ind_x          ($10), ($10),Y, ($10,X)
        #   ind_long(0x10)  ind_long_y       [$10], [$10],Y  (a 24-bit pointer on the direct page)
        #   stack(3)  stack_ind_y(3)         $03,S and ($03,S),Y
        #   :a                               the accumulator itself (ASL A, INC A)
        #
        # A label is a String (+plus+ adds to its address), so it can never be taken for a number.
        #
        #   asm.lda abs(0x0100)              # LDA $0100
        #   asm.adc 4                        # ADC #4
        #   asm.bne "loop"                   # back to "loop" unless the last result was nought
        class W65816
          Operand = Data.define(:mode, :value, :plus)

          # Raised for an instruction the processor does not have — a mistake in the lowering.
          class Error < StandardError; end

          # The eight sums on A, by mnemonic, and the opcode of each with a direct page operand
          # less five: every other way of naming the operand is a fixed step from it (the 65816's
          # opcode table, which keeps these eight in its odd columns).
          ALU = { ora: 0x00, and_a: 0x20, eor: 0x40, adc: 0x60, sta: 0x80, lda: 0xA0, cmp: 0xC0, sbc: 0xE0 }.freeze
          ALU_MODES = { ind_x: 0x01, stack: 0x03, dp: 0x05, ind_long: 0x07, imm: 0x09, abs: 0x0D, long: 0x0F,
                        ind_y: 0x11, ind: 0x12, stack_ind_y: 0x13, dp_x: 0x15, ind_long_y: 0x17, abs_y: 0x19,
                        abs_x: 0x1D, long_x: 0x1F }.freeze

          # The shifts and turns, and the steps from each one's opcode to its other forms.
          SHIFTS = { asl: 0x00, rol: 0x20, lsr: 0x40, ror: 0x60 }.freeze
          SHIFT_MODES = { dp: 0x06, a: 0x0A, abs: 0x0E, dp_x: 0x16, abs_x: 0x1E }.freeze

          # Every other instruction that takes an operand, by mnemonic and way of naming it.
          OPERATED = Ractor.make_shareable({
            inc: { a: 0x1A, dp: 0xE6, abs: 0xEE, dp_x: 0xF6, abs_x: 0xFE },
            dec: { a: 0x3A, dp: 0xC6, abs: 0xCE, dp_x: 0xD6, abs_x: 0xDE },
            ldx: { imm: 0xA2, dp: 0xA6, abs: 0xAE, dp_y: 0xB6, abs_y: 0xBE },
            ldy: { imm: 0xA0, dp: 0xA4, abs: 0xAC, dp_x: 0xB4, abs_x: 0xBC },
            stx: { dp: 0x86, abs: 0x8E, dp_y: 0x96 },
            sty: { dp: 0x84, abs: 0x8C, dp_x: 0x94 },
            stz: { dp: 0x64, dp_x: 0x74, abs: 0x9C, abs_x: 0x9E },
            cpx: { imm: 0xE0, dp: 0xE4, abs: 0xEC },
            cpy: { imm: 0xC0, dp: 0xC4, abs: 0xCC },
            bit: { imm: 0x89, dp: 0x24, abs: 0x2C, dp_x: 0x34, abs_x: 0x3C },
            tsb: { dp: 0x04, abs: 0x0C },
            trb: { dp: 0x14, abs: 0x1C },
            jmp: { abs: 0x4C, ind_abs: 0x6C, ind_abs_x: 0x7C },
            jml: { long: 0x5C, ind_long_abs: 0xDC },
            jsr: { abs: 0x20, ind_abs_x: 0xFC },
            jsl: { long: 0x22 },
            pei: { dp: 0xD4 },
            pea: { abs: 0xF4 }
          })

          # The instructions whose immediate number is as wide as A, and those as wide as X and Y.
          A_WIDE = (ALU.keys + [:bit]).freeze
          X_WIDE = %i[ldx ldy cpx cpy].freeze

          # The branches: one signed byte from the next instruction.
          BRANCHES = { bpl: 0x10, bmi: 0x30, bvc: 0x50, bvs: 0x70, bcc: 0x90, bcs: 0xB0, bne: 0xD0, beq: 0xF0,
                       bra: 0x80 }.freeze

          # Each conditional branch's opposite, for a branch too far for one byte (#branch_long).
          OPPOSITES = { bpl: :bmi, bmi: :bpl, bvc: :bvs, bvs: :bvc, bcc: :bcs, bcs: :bcc, bne: :beq, beq: :bne }.freeze

          # WHAT CHANGES WHAT X HOLDS (#x_holds): the instructions that write X, those that write
          # memory, those that call (whatever is called can do either), and those that never go on to
          # the next instruction, past which X is whatever the way in to the next label brings.
          WRITES_X = %i[tax tsx tyx plx inx dex xce plp ldx].freeze
          WRITES_MEMORY = %i[sta stx sty stz inc dec tsb trb asl lsr rol ror].freeze
          CALLS = %i[jsr jsl].freeze
          # The direct page moved: every direct page address, the noted variable's and the stores
          # #store_misses_noted? reads as plain addresses, means another place.
          MOVES_DIRECT_PAGE = %i[tcd pld].freeze
          ENDS = %i[rts rtl rti stp jmp jml].freeze

          # What X holds past an instruction that never goes on to the next one.
          GONE = :gone

          # The ways of naming a place in memory a store's address is written in the instruction,
          # and the first address of the console's registers, which are not memory (a store there
          # can start a copy into memory).
          WRITTEN_PLACES = %i[dp abs].freeze
          REGISTERS_FROM = 0x2100

          # A long branch is the opposite branch and a BRL; a short one, the branch alone.
          LONG_BRANCH_BYTES = 5
          SHORT_BRANCH_BYTES = 2

          # Where #branch_long wrote one, its condition, and the label it goes to.
          LongBranch = Data.define(:at, :condition, :label)

          # The one-byte instructions that take no operand.
          SINGLES = {
            clc: 0x18, sec: 0x38, cli: 0x58, sei: 0x78, cld: 0xD8, sed: 0xF8, clv: 0xB8,
            tax: 0xAA, tay: 0xA8, txa: 0x8A, tya: 0x98, tsx: 0xBA, txs: 0x9A, txy: 0x9B, tyx: 0xBB,
            tcd: 0x5B, tdc: 0x7B, tcs: 0x1B, tsc: 0x3B, xba: 0xEB, xce: 0xFB,
            pha: 0x48, pla: 0x68, phx: 0xDA, plx: 0xFA, phy: 0x5A, ply: 0x7A, php: 0x08, plp: 0x28,
            phb: 0x8B, plb: 0xAB, phd: 0x0B, pld: 0x2B, phk: 0x4B,
            inx: 0xE8, iny: 0xC8, dex: 0xCA, dey: 0x88,
            rts: 0x60, rtl: 0x6B, rti: 0x40, nop: 0xEA, wai: 0xCB, stp: 0xDB
          }.freeze

          # A place named in an instruction, filled in once everything is placed (Sections::Fixup).
          # Its +kind+ here is :abs (the low 16 bits of its address), :long (all 24), :bank (the top
          # 8), :relative (a branch's distance from the next instruction, one signed byte) or
          # :relative_long (BRL's and PER's, two).
          Fixup = Sections::Fixup

          # A named run of bytes (Sections::Section). Its +home+ here is :first for the cartridge's
          # first bank, where the processor starts and its interrupts land, or :any.
          Section = Sections::Section
          Holding = Sections::Holding

          attr_reader :bytes

          def initialize(name, home: :any, holds: nil)
            @name = name
            @home = home
            @holds = holds
            @bytes = +"".b
            @labels = {}
            @fixups = []
            @long_branches = []
            @wide_a = true
            @wide_x = true
            @x_holds = nil
            @x_at_branches = Hash.new { |states, label| states[label] = [] }
            @joins = {}
          end

          # --- operands ---

          def imm(value, plus = 0) = Operand.new(:imm, value, plus)
          def bank_of(label) = Operand.new(:imm_bank, label, 0)
          def direct(value) = Operand.new(:dp, value, 0)
          def direct_x(value) = Operand.new(:dp_x, value, 0)
          def direct_y(value) = Operand.new(:dp_y, value, 0)
          def abs(value, plus = 0) = Operand.new(:abs, value, plus)
          def abs_x(value, plus = 0) = Operand.new(:abs_x, value, plus)
          def abs_y(value, plus = 0) = Operand.new(:abs_y, value, plus)
          def long(value, plus = 0) = Operand.new(:long, value, plus)
          def long_x(value, plus = 0) = Operand.new(:long_x, value, plus)
          def ind(value) = Operand.new(:ind, value, 0)
          def ind_x(value) = Operand.new(:ind_x, value, 0)
          def ind_y(value) = Operand.new(:ind_y, value, 0)
          def ind_long(value) = Operand.new(:ind_long, value, 0)
          def ind_long_y(value) = Operand.new(:ind_long_y, value, 0)
          def stack(value) = Operand.new(:stack, value, 0)
          def stack_ind_y(value) = Operand.new(:stack_ind_y, value, 0)
          def ind_abs(value, plus = 0) = Operand.new(:ind_abs, value, plus)
          def ind_abs_x(value, plus = 0) = Operand.new(:ind_abs_x, value, plus)
          def ind_long_abs(value, plus = 0) = Operand.new(:ind_long_abs, value, plus)

          # --- the section ---

          # Where the next byte goes, counted from the start of this section.
          def here = @bytes.bytesize

          # Names the next byte. A name is the whole program's: two sections cannot share one.
          #
          # With +join+, the label is only ever reached from above it: by falling through and by
          # branches written before it, never by one written after (the end of a test, the place past
          # its other side). What X holds there is then what it held on every way in, when they agree
          # (#x_holds). Any other label can be reached from anywhere, so X is not known there.
          def label(name, join: false)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            ways_in = @x_at_branches.delete(name) || []
            ways_in << @x_holds unless @x_holds == GONE
            @x_holds = join && ways_in.uniq.length == 1 ? ways_in.first : nil
            @joins[name] = true if join
            name
          end

          # WHAT X HOLDS, as the lowering noted it (#note_x_holds), or nil when it is not known. The
          # lowering reads a slot of a list at X, and X is the slot's number times the slot's width,
          # worked out from a variable: two reads of one variable's slot one after the other need only
          # the first to set X. The note is forgotten as soon as anything could make it untrue: an
          # instruction that writes X, a store to the variable it came from (or one whose address is not
          # written in the instruction, or to the console's registers, which can start a copy into
          # memory), a call, and a label anything could jump to.
          def x_holds = (@x_holds unless @x_holds == GONE)

          # Notes that X holds +key+ (an Array the lowering makes, starting with the address of the
          # variable it was worked out from) until something changes X or that variable.
          def note_x_holds(key) = (@x_holds = key)


          # What the code at the next label finds A, X and Y to be: +a16+ and +xy16+ mark whether
          # they are 16 bits wide. Code jumped to from elsewhere sets them, since the assembler
          # follows REP and SEP only as it writes them in order.
          def widths(a16:, xy16:)
            @wide_a = a16
            @wide_x = xy16
          end

          def wide_a? = @wide_a
          def wide_xy? = @wide_x

          def section
            bytes, labels, fixups = shorten_long_branches
            Section.new(name: @name, bytes: bytes.freeze, labels: labels.freeze, fixups: fixups.freeze,
                        home: @home, holds: @holds)
          end

          # --- data ---

          def data_bytes(*values) = values.flatten.each { |value| emit(byte(value)) }

          # 16-bit words, low byte first; a label is the low 16 bits of its address.
          def data_words(*values)
            values.flatten.each do |value|
              if value.is_a?(String)
                fixup(:abs, value)
                emit(0, 0)
              else
                emit(value & 0xFF, (value >> 8) & 0xFF)
              end
            end
          end

          # 24-bit addresses, low byte first: where each label is.
          def data_longs(*labels)
            labels.flatten.each do |label|
              fixup(:long, label)
              emit(0, 0, 0)
            end
          end

          # --- instructions ---
          #
          # WRITTEN OUT AS SOURCE rather than made from blocks: a method made from a block carries
          # the block with it, and Ruby will not let another Ractor call one, so a game built in a
          # Ractor (as the GBA run's tests build every console's) could not be lowered.

          ALU.each do |name, base|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(operand)
                mode = mode_of(:#{name}, operand)
                refuse_mode!(:#{name}, operand) if :#{name} == :sta && mode == :imm # its place is BIT #'s
                emit_operated(:#{name}, operand, #{base} + ALU_MODES.fetch(mode))
              end
            RUBY
          end

          SHIFTS.each do |name, base|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(operand = :a)
                emit_operated(:#{name}, operand, #{base} + SHIFT_MODES.fetch(mode_of(:#{name}, operand)))
              end
            RUBY
          end

          OPERATED.each_key do |name|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(operand = :a)
                opcode = OPERATED.fetch(:#{name}).fetch(mode_of(:#{name}, operand)) { refuse_mode!(:#{name}, operand) }
                emit_operated(:#{name}, operand, opcode)
              end
            RUBY
          end

          SINGLES.each { |name, opcode| class_eval("def #{name} = emit_single(:#{name}, #{opcode})", __FILE__, __LINE__) }

          BRANCHES.each do |name, opcode|
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{name}(target)
                note_way_in(target)
                emit(#{opcode})
                fixup(:relative, target)
                emit(0)
                @x_holds = GONE if :#{name} == :bra
              end
            RUBY
          end

          # BRL: anywhere in the bank, two signed bytes from the next instruction.
          def brl(target)
            note_way_in(target)
            emit_brl(target)
            @x_holds = GONE
          end

          # A conditional branch to anywhere in the bank: the opposite branch over a BRL. Where the
          # target turns out to be in this section and in reach of one byte, #section makes it the
          # short branch instead (#shorten_long_branches).
          def branch_long(condition, target)
            note_way_in(target)
            @long_branches << LongBranch.new(at: here, condition: condition, label: target.to_s)
            emit(BRANCHES.fetch(OPPOSITES.fetch(condition)), 3)
            emit_brl(target)
          end

          # REP and SEP clear and set the processor's flags; the widths of A and of X and Y follow.
          # Making X 8 bits wide empties its high byte, so a note of what it holds is forgotten.
          def rep(flags)
            emit(0xC2, flags & 0xFF)
            @wide_a = true if flags.anybits?(0x20)
            @wide_x = true if flags.anybits?(0x10)
            @x_holds = nil if flags.anybits?(0x10)
          end

          def sep(flags)
            emit(0xE2, flags & 0xFF)
            @wide_a = false if flags.anybits?(0x20)
            @wide_x = false if flags.anybits?(0x10)
            @x_holds = nil if flags.anybits?(0x10)
          end

          # MVN and MVP copy a block: X from, Y to, A+1 bytes, between the two banks named.
          def mvn(to_bank, from_bank) = emit_block_copy(0x54, to_bank, from_bank)
          def mvp(to_bank, from_bank) = emit_block_copy(0x44, to_bank, from_bank)

          private

          def mode_of(name, operand)
            return :imm if operand.is_a?(Integer)
            return :a if operand == :a
            raise Error, "#{name} takes an Operand, not #{operand.inspect}" unless operand.is_a?(Operand)

            operand.mode == :imm_bank ? :imm : operand.mode
          end

          def refuse_mode!(name, operand)
            raise Error, "the 65816 has no #{name.to_s.upcase} with #{mode_of(name, operand)}"
          end

          def emit_operated(name, operand, opcode)
            forget_x_for(name, operand)
            operand = Operand.new(:imm, operand, 0) if operand.is_a?(Integer)
            return emit(opcode) if operand == :a

            emit(opcode)
            case operand.mode
            when :imm then emit_immediate(name, operand)
            when :imm_bank
              fixup(:bank, operand.value)
              emit(0)
              emit(0) if wide_immediate?(name)
            when :dp, :dp_x, :dp_y, :ind, :ind_x, :ind_y, :ind_long, :ind_long_y, :stack, :stack_ind_y
              emit(byte(operand.value))
            when :abs, :abs_x, :abs_y, :ind_abs, :ind_abs_x, :ind_long_abs then emit_address(operand, :abs, 2)
            when :long, :long_x then emit_address(operand, :long, 3)
            else refuse_mode!(name, operand)
            end
          end

          def wide_immediate?(name)
            return @wide_a if A_WIDE.include?(name)
            return @wide_x if X_WIDE.include?(name)

            raise Error, "#{name} has no immediate form"
          end

          def emit_immediate(name, operand)
            if operand.value.is_a?(String)
              raise Error, "#{name} ##{operand.value} needs a 16-bit register" unless wide_immediate?(name)

              fixup(:abs, operand.value, operand.plus)
              return emit(0, 0)
            end
            value = operand.value + operand.plus
            wide_immediate?(name) ? emit(value & 0xFF, (value >> 8) & 0xFF) : emit(byte(value))
          end

          def emit_address(operand, kind, size)
            if operand.value.is_a?(String)
              fixup(kind, operand.value, operand.plus)
              return emit(*Array.new(size, 0))
            end
            value = operand.value + operand.plus
            emit(*Array.new(size) { |i| (value >> (8 * i)) & 0xFF })
          end

          def byte(value)
            raise Error, "#{value} does not fit in a byte" unless value.between?(-128, 255)

            value & 0xFF
          end

          def fixup(kind, label, plus = 0) = @fixups << Fixup.new(offset: here, kind: kind, label: label.to_s, plus: plus)

          def emit(*values) = @bytes << values.pack("C*")

          def emit_single(name, opcode)
            forget_x_for(name, :a)
            emit(opcode)
          end

          def emit_brl(target)
            emit(0x82)
            fixup(:relative_long, target)
            emit(0, 0)
          end

          def emit_block_copy(opcode, to_bank, from_bank)
            @x_holds = nil
            emit(opcode, to_bank, from_bank)
          end

          # The note of what X holds made untrue by +name+ with +operand+, forgotten. Written before
          # the instruction, which does not change what that instruction does.
          def forget_x_for(name, operand)
            return @x_holds = GONE if ENDS.include?(name)
            return @x_holds = nil if WRITES_X.include?(name) || CALLS.include?(name) || MOVES_DIRECT_PAGE.include?(name)
            return unless @x_holds.is_a?(Array) && WRITES_MEMORY.include?(name) && operand != :a

            @x_holds = nil unless store_misses_noted?(operand)
          end

          # Whether a store to +operand+ surely leaves the variable X was worked out from alone: its
          # address is written in the instruction, is memory, and the two bytes stored there do not
          # reach the variable's low half.
          def store_misses_noted?(operand)
            return false unless operand.is_a?(Operand) && WRITTEN_PLACES.include?(operand.mode) && operand.value.is_a?(Integer)

            address = operand.value + operand.plus
            noted = @x_holds.first
            address < REGISTERS_FROM && !(noted - 1..noted + 1).cover?(address)
          end

          # A branch to +target+ written, with what X holds now as one way in to it. A label marked a
          # join (#label) is never branched to from below it, which would have to be a loop.
          def note_way_in(target)
            target = target.to_s
            raise Error, "#{target} is a join, and a branch from below it would make it a loop" if @joins.key?(target)
            return if @labels.key?(target)

            @x_at_branches[target] << (@x_holds == GONE ? nil : @x_holds)
          end

          # LONG BRANCHES MADE SHORT WHERE THEY REACH. A conditional branch carries one signed byte, so
          # #branch_long writes the opposite branch over a BRL, five bytes, for a target that may be
          # anywhere in the bank: where a label will be is not known while code is written, and most
          # are written after the branch to them. On the path a branch does not take, that is two
          # instructions and six or seven cycles where one short branch is two or three. Once the
          # section is whole every label in it is known, so each long branch whose target is in this
          # section and in reach of one byte becomes the two-byte branch, and everything after it
          # moves three bytes back. Moving back only brings branches nearer, so this is done again
          # until no more reach. A target in another section is left long, since where that section
          # goes is the Linker's.
          #
          # The bytes, labels and fixups with the short branches in.
          def shorten_long_branches
            return [@bytes.dup, @labels.dup, @fixups.dup] if @long_branches.empty?

            shortened = shortened_long_branches
            [bytes_with_short_branches(shortened), @labels.transform_values { |offset| moved_back(offset, shortened) },
             fixups_with_short_branches(shortened)]
          end

          # The places of the long branches that reach their targets as short ones, in order.
          def shortened_long_branches
            shortened = []
            waiting = @long_branches.select { |branch| @labels.key?(branch.label) }
            loop do
              reach = waiting.select do |branch|
                distance = moved_back(@labels.fetch(branch.label), shortened) - (moved_back(branch.at, shortened) + SHORT_BRANCH_BYTES)
                distance.between?(-128, 127)
              end
              return shortened if reach.empty?

              shortened = (shortened + reach.map(&:at)).sort
              waiting -= reach
            end
          end

          # Where the byte at +offset+ goes once each of the long branches at +shortened+ (in order)
          # is made short.
          def moved_back(offset, shortened)
            before = shortened.bsearch_index { |at| at + LONG_BRANCH_BYTES > offset } || shortened.length
            offset - (before * (LONG_BRANCH_BYTES - SHORT_BRANCH_BYTES))
          end

          def bytes_with_short_branches(shortened)
            conditions = @long_branches.to_h { |branch| [branch.at, branch.condition] }
            bytes = +"".b
            from = 0
            shortened.each do |at|
              bytes << @bytes.byteslice(from, at - from) << [BRANCHES.fetch(conditions.fetch(at)), 0].pack("C*")
              from = at + LONG_BRANCH_BYTES
            end
            bytes << @bytes.byteslice(from, @bytes.bytesize - from)
          end

          # Every fixup moved back, the BRL's of a shortened branch left out, and a one-byte
          # distance for each short branch.
          def fixups_with_short_branches(shortened)
            inside = lambda do |offset|
              before = shortened.bsearch_index { |start| start > offset } || shortened.length
              before.positive? && offset < shortened[before - 1] + LONG_BRANCH_BYTES
            end
            kept = @fixups.reject { |fixup| inside.call(fixup.offset) }.map do |fixup|
              fixup.with(offset: moved_back(fixup.offset, shortened))
            end
            labels = @long_branches.to_h { |branch| [branch.at, branch.label] }
            kept + shortened.map do |at|
              Fixup.new(offset: moved_back(at, shortened) + 1, kind: :relative, label: labels.fetch(at), plus: 0)
            end
          end
        end
      end
    end
  end
end
