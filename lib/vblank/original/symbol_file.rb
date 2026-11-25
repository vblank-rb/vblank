# frozen_string_literal: true

require_relative "labels"

module VBlank
  module Original
    # The symbol file an assembler writes, read into Labels. Each assembler (or linker) says where it
    # put every label in a format of its own, and each console maps its cartridge and RAM into the
    # processor's addresses its own way; a reader here knows one of each, and hands back Labels a
    # port's harvest saves:
    #
    #   labels = VBlank::Original::SymbolFile.rgblink(File.read(built.path("game.sym")))
    #   labels.write("data/labels.json") if labels.stale?("data/labels.json")
    #
    # A label inside another (`Start.loop`, a local label) is left out of the cartridge's labels unless
    # +local_labels: true+: most are named for their address and there are many. In RAM a dotted name
    # is a field of a structure (`player_1.x_position`), the name a probe wants, so it stays.
    #
    # Each reader takes the file's text. An address the console maps to neither the cartridge nor RAM
    # (a hardware register, a constant) is left out.
    module SymbolFile
      module_function

      # Game Boy (rgblink, RGBDS's linker, `-n`): `bank:address name`, both in hex, `;` a comment
      # (rgblink(1), "The .sym file"). The processor sees bank 0 at $0000-$3FFF and the bank switched
      # in at $4000-$7FFF, so a label in bank n at $4000+a is at n * $4000 + a in the file. $8000 and up
      # is video memory, the cartridge's RAM, work RAM and high RAM (Pan Docs, "Memory Map").
      RGBLINK_LINE = /\A(\h+):(\h+)\s+(\S+)\s*\z/
      GAME_BOY_BANK_BYTES = 0x4000
      GAME_BOY_RAM_START = 0x8000

      def rgblink(text, local_labels: false)
        labels = text.each_line.filter_map do |line|
          bank, address, name = line.match(RGBLINK_LINE)&.captures
          next unless name

          bank = bank.to_i(16)
          address = address.to_i(16)
          if address >= GAME_BOY_RAM_START
            Labels::Label.new(name: name, space: :ram, address: address)
          elsif local_labels || !name.include?(".")
            offset = bank.zero? ? address : (bank * GAME_BOY_BANK_BYTES) + address - GAME_BOY_BANK_BYTES
            Labels::Label.new(name: name, space: :rom, address: address, offset: offset)
          end
        end
        Labels.new(labels, rom_bank_bytes: GAME_BOY_BANK_BYTES)
      end

      # Super Nintendo (sfcasm's symbol table): `bbaaaa name`, the 24-bit address in six hex digits.
      # Work RAM is banks $7E and $7F, its first 8 KB seen in banks $00-$3F and $80-$BF too. Where
      # the cartridge is depends on how the board maps it (fullsnes, "SNES Cart LoROM/HiROM
      # Mapping"): HiROM shows it whole from bank $C0, 64 KB a bank; LoROM in the upper half of each
      # bank from $80 (and $00), 32 KB a bank.
      SFCASM_LINE = /\A(\h{6})\s+(\S+)\s*\z/
      SNES_MAPPINGS = { hirom: 0x10000, lorom: 0x8000 }.freeze
      SNES_WORK_RAM_BANKS = [0x7E, 0x7F].freeze
      SNES_LOW_RAM_BYTES = 0x2000

      def sfcasm(text, mapping:, local_labels: false)
        unless SNES_MAPPINGS.key?(mapping)
          raise ArgumentError, "The mapping #{mapping.inspect} is not known. Give mapping: :hirom or mapping: :lorom."
        end

        labels = text.each_line.filter_map do |line|
          address, name = line.match(SFCASM_LINE)&.captures
          next unless name

          address = address.to_i(16)
          if snes_ram?(address)
            Labels::Label.new(name: name, space: :ram, address: address)
          elsif (offset = snes_offset(address, mapping)) && (local_labels || !name.include?("."))
            Labels::Label.new(name: name, space: :rom, address: address, offset: offset)
          end
        end
        Labels.new(labels, rom_bank_bytes: SNES_MAPPINGS.fetch(mapping))
      end

      def snes_ram?(address)
        bank = address >> 16
        SNES_WORK_RAM_BANKS.include?(bank) || ((bank & 0x7F) < 0x40 && (address & 0xFFFF) < SNES_LOW_RAM_BYTES)
      end

      # Where a cartridge address is in the file, or nil for an address that is not the cartridge.
      def snes_offset(address, mapping)
        bank = address >> 16
        low = address & 0xFFFF
        if mapping == :hirom
          return address - 0xC00000 if bank >= 0xC0
          return ((bank & 0x3F) << 16) | low if (bank & 0x7F) < 0x40 && low >= 0x8000

          nil
        else
          return nil if low < 0x8000 || (bank & 0x7F) >= 0x7E

          ((bank & 0x7F) * 0x8000) + (low - 0x8000)
        end
      end

      # SEGA GENESIS (asm68k's listing, `/l`, or a compatible assembler's): a line for each source
      # line, the address in eight hex digits, then `=` and the value for a name given one (`equ`,
      # `rs`), and the source line itself from the 37th column. The cartridge is at address 0, so a
      # label's address is its offset. Work RAM is $FF0000-$FFFFFF (plutiedev, "Memory map"); a name
      # reserved there with `rs.b`, `rs.w` or `rs.l` is a variable of that width, and its size is the
      # count times the width where the count is a plain number, else up to the next variable. A
      # local label (`.loop`) belongs to the label before it, as asm68k reads them with `/o l.`.
      LISTING_SOURCE_COLUMN = 36
      LISTING_LINE = /\A\h{8} /
      LISTING_LABEL = /\A([A-Za-z_.][A-Za-z0-9_.]*):/
      LISTING_WIDTHS = { "rs.b" => 1, "rs.w" => 2, "rs.l" => 4 }.freeze
      GENESIS_RAM = (0xFF0000..0xFFFFFF)
      GENESIS_CARTRIDGE_END = 0x400000

      def asm68k_listing(text, local_labels: false)
        labels = []
        reserved = []
        global = nil
        text.each_line do |raw|
          line = raw.delete("\0").chomp
          next unless line.match?(LISTING_LINE)

          source = line[LISTING_SOURCE_COLUMN..].to_s
          if line[9] == "="
            reserved << listing_reservation(source, line[10, 8].to_i(16))
          elsif (name = source[LISTING_LABEL, 1])
            global = name unless name.start_with?(".")
            full = name.start_with?(".") && global ? "#{global}#{name}" : name
            labels << listing_label(full, line[0, 8].to_i(16), local_labels)
          end
        end
        Labels.new(labels.compact + reserved_variables(reserved.compact))
      end

      # [name, address, width, count] for a name `rs` reserves in work RAM, or nil.
      def listing_reservation(source, value)
        name, operation, count = source.strip.split(/\s+/, 3)
        width = LISTING_WIDTHS[operation.to_s.downcase]
        return nil unless width && GENESIS_RAM.cover?(value) && name.match?(/\A[A-Za-z_]\w*\z/)

        count = count.to_s.strip.split(/[\s;]/).first.to_s
        [name, value, width, count.match?(/\A(\d+|\$\h+)\z/) ? Integer(count.sub("$", "0x")) : nil]
      end

      def listing_label(name, address, local_labels)
        return Labels::Label.new(name: name, space: :ram, address: address) if GENESIS_RAM.cover?(address)
        return nil if address >= GENESIS_CARTRIDGE_END || (name.include?(".") && !local_labels)

        Labels::Label.new(name: name, space: :rom, address: address, offset: address)
      end

      def reserved_variables(reserved)
        addresses = reserved.map { it[1] }.uniq.sort
        reserved.map do |name, address, width, count|
          following = addresses.bsearch { it > address }
          size = count ? count * width : (following ? following - address : width)
          Labels::Label.new(name: name, space: :ram, address: address, width: width, size: size)
        end
      end

      # Game Boy Advance (the GNU linker's map, `ld -Map`): under "Linker script and memory map", a
      # symbol is a line of its address and its name alone; a section's line has its size and file
      # too, and an assignment an `=`. The cartridge is at $08000000, work RAM at $02000000 (256 KB)
      # and $03000000 (32 KB) (GBATEK, "GBA Memory Map").
      MAP_START = "Linker script and memory map"
      MAP_SYMBOL = /\A\s+0x(\h+)\s+([A-Za-z_.$][\w.$]*)\s*\z/
      ADVANCE_CARTRIDGE = (0x08000000...0x0A000000)
      ADVANCE_RAM = [(0x02000000...0x02040000), (0x03000000...0x03008000)].freeze

      def gnu_ld_map(text)
        started = false
        labels = text.each_line.filter_map do |line|
          started ||= line.start_with?(MAP_START)
          address, name = line.match(MAP_SYMBOL)&.captures if started
          next unless name

          address = address.to_i(16)
          if ADVANCE_CARTRIDGE.cover?(address)
            Labels::Label.new(name: name, space: :rom, address: address, offset: address - ADVANCE_CARTRIDGE.begin)
          elsif ADVANCE_RAM.any? { it.cover?(address) }
            Labels::Label.new(name: name, space: :ram, address: address)
          end
        end
        Labels.new(labels)
      end

      private_class_method :snes_ram?, :snes_offset, :listing_reservation, :listing_label, :reserved_variables
    end
  end
end
