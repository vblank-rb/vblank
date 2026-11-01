# frozen_string_literal: true

module VBlank
  module Diagnostics
    # `dump_func` ON THE GAME BOY COLOR: the code a routine was made into, read back out of the
    # finished cartridge in the words of the Color's processor (the SM83), one instruction a line.
    # It is how a slow routine is read rather than guessed at: a variable kept in four bytes is four
    # reads, there on the page.
    #
    # The build's record names what a bare address cannot: the game's variables, the runtime's
    # routines, and the labels jumped to inside the routine. A routine too big for a bank was cut
    # into parts, and each part is listed.
    class SM83Listing
      REGISTERS = %w[b c d e h l [hl] a].freeze
      PAIRS = %w[bc de hl sp].freeze
      STACKED = %w[bc de hl af].freeze
      CONDITIONS = %w[nz z nc c].freeze
      SUMS = ["add a,", "adc a,", "sub ", "sbc a,", "and ", "xor ", "or ", "cp "].freeze
      TURNS = %w[rlc rrc rl rr sla sra swap srl].freeze

      # The instructions of one byte with nothing to work out.
      SINGLES = { 0x00 => "nop", 0x07 => "rlca", 0x0F => "rrca", 0x17 => "rla", 0x1F => "rra", 0x27 => "daa",
                  0x2F => "cpl", 0x37 => "scf", 0x3F => "ccf", 0x76 => "halt", 0xC9 => "ret", 0xD9 => "reti",
                  0xE9 => "jp hl", 0xF3 => "di", 0xF9 => "ld sp,hl", 0xFB => "ei", 0x02 => "ld [bc],a",
                  0x12 => "ld [de],a", 0x22 => "ld [hl+],a", 0x32 => "ld [hl-],a", 0x0A => "ld a,[bc]",
                  0x1A => "ld a,[de]", 0x2A => "ld a,[hl+]", 0x3A => "ld a,[hl-]", 0xE2 => "ld [c],a",
                  0xF2 => "ld a,[c]" }.freeze

      BANK_SIZE = 0x4000 # what each bank of the cartridge holds, the size of its window in the address space
      HIGH_PAGE = 0xFF00 # where `ldh`'s one-byte address counts from

      # The instruction at +at+ in +bytes+, which sits at +address+: [its words, how many bytes it
      # takes]. +name+ turns an address into what it is called, for the three kinds of operand
      # that are one. A byte that is no instruction is said as a byte.
      def self.decode(bytes, at, address, name: ->(place) { format("$%04X", place) })
        op = bytes.getbyte(at)
        n = bytes.getbyte(at + 1).to_i
        nn = n | (bytes.getbyte(at + 2).to_i << 8)
        return [SINGLES.fetch(op), 1] if SINGLES.key?(op)
        return [REGISTER_LOAD.call(op), 1] if op.between?(0x40, 0x7F)
        return ["#{SUMS[(op >> 3) & 7]}#{REGISTERS[op & 7]}", 1] if op.between?(0x80, 0xBF)
        return [bit_op(n), 2] if op == 0xCB

        relative = address + 2 + (n >= 0x80 ? n - 0x100 : n)
        by_pattern(op, n, nn, relative, name) || [format("db $%02X", op), 1]
      end

      REGISTER_LOAD = ->(op) { "ld #{REGISTERS[(op >> 3) & 7]},#{REGISTERS[op & 7]}" }
      private_constant :REGISTER_LOAD

      def self.bit_op(n)
        operand = REGISTERS[n & 7]
        number = (n >> 3) & 7
        case n >> 6
        when 0 then "#{TURNS[number]} #{operand}"
        when 1 then "bit #{number},#{operand}"
        when 2 then "res #{number},#{operand}"
        else "set #{number},#{operand}"
        end
      end

      # The instructions with a byte or a word after them, or a register in their bits.
      def self.by_pattern(op, n, nn, relative, name)
        pair = PAIRS[op >> 4 & 3]
        condition = CONDITIONS[(op >> 3) & 3]
        register = REGISTERS[(op >> 3) & 7]
        word = name.call(nn)
        case op
        when 0x10 then ["stop", 2]
        when 0x08 then ["ld [#{word}],sp", 3]
        when 0x18 then ["jr #{name.call(relative)}", 2]
        when 0x20, 0x28, 0x30, 0x38 then ["jr #{condition},#{name.call(relative)}", 2]
        when 0xC3 then ["jp #{word}", 3]
        when 0xCD then ["call #{word}", 3]
        when 0xC0, 0xC8, 0xD0, 0xD8 then ["ret #{condition}", 1]
        when 0xC2, 0xCA, 0xD2, 0xDA then ["jp #{condition},#{word}", 3]
        when 0xC4, 0xCC, 0xD4, 0xDC then ["call #{condition},#{word}", 3]
        when 0xEA then ["ld [#{word}],a", 3]
        when 0xFA then ["ld a,[#{word}]", 3]
        when 0xE0 then ["ldh [#{name.call(HIGH_PAGE + n)}],a", 2]
        when 0xF0 then ["ldh a,[#{name.call(HIGH_PAGE + n)}]", 2]
        when 0xE8 then [format("add sp,%d", n >= 0x80 ? n - 0x100 : n), 2]
        when 0xF8 then [format("ld hl,sp%+d", n >= 0x80 ? n - 0x100 : n), 2]
        when 0x21 then ["ld hl,#{word}", 3]
        when 0x01, 0x11, 0x31 then [format("ld %s,$%04X", pair, nn), 3]
        when 0x03, 0x13, 0x23, 0x33 then ["inc #{pair}", 1]
        when 0x0B, 0x1B, 0x2B, 0x3B then ["dec #{pair}", 1]
        when 0x09, 0x19, 0x29, 0x39 then ["add hl,#{pair}", 1]
        when 0xC1, 0xD1, 0xE1, 0xF1 then ["pop #{STACKED[(op >> 4) & 3]}", 1]
        when 0xC5, 0xD5, 0xE5, 0xF5 then ["push #{STACKED[(op >> 4) & 3]}", 1]
        else by_low_bits(op, n, register)
        end
      end

      # The instructions told by their low three bits.
      def self.by_low_bits(op, n, register)
        case op & 0xC7
        when 0x04 then ["inc #{register}", 1]
        when 0x05 then ["dec #{register}", 1]
        when 0x06 then [format("ld %s,$%02X", register, n), 2]
        when 0xC6 then [format("%s$%02X", SUMS[(op >> 3) & 7], n), 2]
        when 0xC7 then [format("rst $%02X", op & 0x38), 1]
        end
      end
      private_class_method :bit_op, :by_pattern, :by_low_bits

      # @param rom [Cartridge::GBCROM] the built cartridge, with the record of its build
      # @param out [IO] where the listing is written
      # @param err [IO] where a routine that is not there is said
      def initialize(rom, out: $stdout, err: $stderr)
        @rom = rom
        @built = rom.built
        @out = out
        @err = err
      end

      # List each named routine. A scene is a routine named _scene_<name>.
      def dump(names) = names.each { |name| list_routine(name) }

      private

      def list_routine(name)
        said = [name, :"_scene_#{name}"].filter_map { |tried| @built.code["routine #{tried}"] }.first
        return @err.puts("[dump_func] :#{name} not found or not emitted") unless said

        whose = @built.routine_at(said.bank, said.address)
        @built.routines.select { |held| held.routine == whose }.each { |part| list_part(name, part) }
      end

      def list_part(name, part)
        @out.puts(format("=== func :%s (bank %d, $%04X..$%04X) ===", name, part.bank, part.addresses.begin, part.addresses.end))
        numbers_from = numbers_start(part)
        address = part.addresses.begin
        while address < numbers_from
          said, size = self.class.decode(bytes_at(part.bank), offset_in(address), address, name: ->(place) { name_of(place, part.bank) })
          @out.puts(format("  %02X:%04X: %s", part.bank, address, said))
          address += size
        end
        list_numbers(part, numbers_from)
      end

      # Where the numbers kept after the routine's return begin, or its end when it has none.
      def numbers_start(part)
        @built.code.filter_map { |label, place| place.address if number_label?(label) && same_part?(part, place) }.min || part.addresses.end
      end

      def number_label?(label) = label.match?(/\.number#\d+\z/)
      def same_part?(part, place) = place.bank == part.bank && part.addresses.cover?(place.address)

      # Numbers are kept four bytes each, lowest first.
      def list_numbers(part, from)
        (from...part.addresses.end).step(4) do |address|
          @out.puts(format("  %02X:%04X: .long %d", part.bank, address, bytes_at(part.bank)[offset_in(address), 4].unpack1("l<")))
        end
      end

      # A bank's bytes, as the processor sees them in view.
      def bytes_at(bank) = @rom.bytes.byteslice(bank * BANK_SIZE, BANK_SIZE)
      def offset_in(address) = address % BANK_SIZE

      # What +place+ is called in a routine in +bank+: a variable, a label in the code in view, a
      # part of the runtime's memory, or the address itself.
      def name_of(place, bank)
        variables[place] || labels[[place < BANK_SIZE ? 0 : bank, place]] || format("$%04X", place)
      end

      # A variable's bytes past its first read as the variable and how far in. Whole numbers span
      # four bytes and a kept one fewer, so each byte up to the next variable is named.
      def variables
        @variables ||= begin
          sized = @built.variables.to_h { |name, at| [at, name.to_s] }
          kept = @built.source_program
          @built.variables.each do |name, at|
            (1...variable_bytes(kept, name)).each { |byte| sized[at + byte] = "#{name}+#{byte}" }
          end
          sized.merge(@built.runtime.to_h { |name, at| [at, name.tr(' ', '_')] })
        end
      end

      def variable_bytes(program, name)
        width = program.kept_width_of(name)
        width ? IR::KeptWidths::BYTES.fetch(width) : 4
      end

      # The code's labels by [bank, address]. A label inside a routine reads as the part after the
      # routine's name, and a section's own as it is.
      def labels
        @labels ||= @built.code.each_with_object({}) do |(label, place), named|
          named[[place.bank, place.address]] ||= label.include?(".") ? ".#{label.split('.').last}" : label
        end
      end
    end
  end
end
