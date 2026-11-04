# frozen_string_literal: true

require "json"

module VBlank
  module Cartridge
    # A SUPER NINTENDO CARTRIDGE: the banks the SNES lowering linked, laid out the LoROM way, with
    # the header and vectors the console reads.
    #
    # The header sits at $FFC0 of the first bank, which in a LoROM file is offset $7FC0: a title of
    # 21 characters, the map mode (how the cartridge's bytes are laid out in the processor's view:
    # LoROM, read at the faster speed), the kind of cartridge (ROM alone, or with battery-backed
    # RAM for saves), how big the ROM and that RAM are (each as 2^n kilobytes), the region, the
    # maker and version, and a checksum: every byte of the cartridge added up, kept to 16 bits,
    # beside its complement. The console itself checks none of it; emulators and flash carts read
    # it to tell how to run the cartridge.
    #
    # After the header come the vectors, the 16-bit addresses in bank $00 where the processor goes
    # when it starts (reset) and when an interrupt comes. The processor starts in its 6502
    # emulation mode, so reset is the emulation one; the game switches to native mode at once, and
    # the vertical blank's interrupt (NMI) and the rest are the native ones from then on.
    #
    # THE BOARD. A plain cartridge is ROM alone (with battery-backed RAM when the game saves). A
    # cartridge with a Super FX 2 is a board of its own, and its header says so, because an emulator
    # or a flash cart reads the header to know which board to be:
    #
    #   - the map mode is LoROM read SLOWLY ($20): the chip shares the cartridge's ROM with the
    #     console, and the board's ROM is only ever read at the slow speed. Its ROM is still seen in
    #     banks $80 and up as well as $00 and up (bsnes's board table, GSU-RAM), so the code sits
    #     where it does on a plain cartridge; only nothing asks for the faster speed.
    #   - the cartridge type is $14, "ROM, a Super FX and its RAM" ($15 when a battery keeps that
    #     RAM): the high four bits $1 say Super FX, which is how bsnes picks the board.
    #   - the extended header says how much RAM the chip has: 64K, seen by the console at $70:0000,
    #     or 128K for a game that saves, the second 64K at $71:0000 (SUPER_FX says why).
    #   - the ROM is at most 2 megabytes, banks $00-$3F, which is all the chip can read.
    #
    # Real Super FX games (Star Fox, Yoshi's Island, Doom) carry the same map mode and type.
    #
    # References: https://problemkaputt.de/fullsnes.htm#snescartridgeromheader and #snescartgsunsuperfx;
    # bsnes, heuristics/super-famicom.cpp (how it reads the header) and boards.bml (GSU-RAM).
    class SNESROM
      include Console::SNESHardware

      SMALLEST = 0x8000

      # A kind of cartridge board: its +name+, the +map_mode+ its header says, whether the console
      # may read it at the faster speed (+fast+), the most 32K banks it holds, how much RAM a chip
      # on it has of its own (+chip_ram_bytes+, nought for none), and the bank the console sees a
      # save in (+save_bank+).
      Board = Data.define(:name, :map_mode, :fast, :most_banks, :chip_ram_bytes, :save_bank) do
        # How far into the cartridge's RAM the save starts: nought on a plain board, whose RAM is
        # all the save; on a chip's board, past the bank or banks the chip works in.
        def save_offset = (save_bank - SRAM_BANK) << 16

        # How much RAM a chip on the board has, as the extended header says it: its own, and with
        # a save (+save_bytes+ not nought) the bank the save is kept in as well.
        def chip_ram_bytes_with(save_bytes)
          return chip_ram_bytes if save_bytes.zero?

          size = chip_ram_bytes
          size *= 2 while size < save_offset + save_bytes
          size
        end
      end

      PLAIN = Board.new(name: :plain, map_mode: LOROM_FAST, fast: true, most_banks: 128, chip_ram_bytes: 0,
                        save_bank: SRAM_BANK)
      # THE SAVE ON A SUPER FX BOARD. The chip's 64K at $70 is all spoken for (Runtime::ChipPaint):
      # the painted screen's 56K, the tiles' generations, the list of tiles the chip readied, the
      # blocks a rectangle and a picture are handed over in, and the chip's numbers in what is
      # left. A save of 32K does not fit beside them. So a game that saves gets a board with 128K
      # of the chip's RAM, and its save is the first 32K of the second bank, $71:0000-$71:7FFF
      # (GSU_SAVE_BANK), which the chip never reaches; the rest of that bank is spare. bsnes keeps
      # all 128K as the cartridge's save file, the save 64K into it (Diagnostics::SNESReading).
      # A game that does not save keeps the 64K board, byte for byte as before.
      SUPER_FX = Board.new(name: :super_fx, map_mode: LOROM_SLOW, fast: false, most_banks: 64,
                           chip_ram_bytes: 0x10000, save_bank: GSU_SAVE_BANK)
      BOARDS = { plain: PLAIN, super_fx: SUPER_FX }.freeze

      # The native vectors, and the emulation ones, by the name the lowering gives them.
      VECTORS = { cop: NATIVE_COP_VECTOR, brk: NATIVE_BRK_VECTOR, abort: NATIVE_ABORT_VECTOR, nmi: NATIVE_NMI_VECTOR,
                  irq: NATIVE_IRQ_VECTOR, emulation_cop: EMULATION_COP_VECTOR, emulation_abort: EMULATION_ABORT_VECTOR,
                  emulation_nmi: EMULATION_NMI_VECTOR, reset: RESET_VECTOR,
                  emulation_irq: EMULATION_IRQ_VECTOR }.freeze

      attr_reader :bytes

      # What the build worked out about the cartridge, for the tools that read a running one
      # back, or nil.
      attr_reader :built

      # A size as the header says it, a byte: the power of two of its kilobytes (32K is 5); and the
      # bytes a header's byte says. SNESReading's save file is the size the header says.
      def self.size_byte(bytes) = Math.log2(bytes / 1024).to_i
      def self.bytes_of_size_byte(byte) = 1024 << byte

      # How far into the cartridge's RAM, and so into the emulator's save file, the save starts,
      # read from a cartridge's header: SUPER_FX's save offset on a Super FX board whose extended
      # header says more RAM than the chip works in (one VBlank built for a game that saves), and
      # nought on any other, a Super FX game of the day included.
      def self.save_offset_of(bytes)
        place = header_place_of(bytes)
        return 0 unless place
        return 0 unless (bytes.getbyte(CARTRIDGE_TYPE_AT + place.shift) >> 4) == (SUPER_FX_RAM >> 4)
        return 0 unless bytes.getbyte(MAKER_AT + place.shift) == EXTENDED_HEADER

        chip_ram = bytes_of_size_byte(bytes.getbyte(EXPANSION_RAM_AT + place.shift) & 0x0F)
        chip_ram > SUPER_FX.chip_ram_bytes ? SUPER_FX.save_offset : 0
      end

      # Whether a cartridge's header says its RAM is kept by a battery, so is a save at all. The low
      # half of the type byte says what is on the board: 2 is RAM and a battery, 5 and 6 a chip with
      # a battery (with RAM and without), 9 and $A those with a clock too. A Super FX board's RAM is
      # there either way, the chip's working memory; only with a battery is any of it a save.
      BATTERY_KINDS = [0x2, 0x5, 0x6, 0x9, 0xA].freeze
      def self.battery?(bytes)
        place = header_place_of(bytes) or return false
        BATTERY_KINDS.include?(bytes.getbyte(CARTRIDGE_TYPE_AT + place.shift) & 0x0F)
      end

      # +banks+ is the linked cartridge, its first 32K first. +vectors+ names where each vector
      # points, by VECTORS's names; one not named points where reset does.
      # +save_bytes+ is how much battery-backed RAM it has, a power of two from 2K, or nought.
      # +board+ is the kind of board (BOARDS), a plain one unless said.
      def initialize(banks, title:, vectors:, save_bytes: 0, built: nil, board: PLAIN)
        @built = built
        @board = board
        unless save_bytes.zero? || (save_bytes >= 0x800 && (save_bytes & (save_bytes - 1)).zero?)
          raise ArgumentError, "a Super Nintendo cartridge keeps a power of two from 2K of save RAM, not #{save_bytes} bytes"
        end
        if banks.size > board.most_banks
          raise ArgumentError, "a #{board.name} board holds #{board.most_banks} banks, not #{banks.size}"
        end

        @bytes = padded(banks.join.b)
        write_header(title, save_bytes)
        write_extended_header(save_bytes) unless board.chip_ram_bytes.zero?
        write_vectors(vectors)
        write_checksum
      end

      def size = @bytes.bytesize

      # Where a cartridge file's header can be, for each of the two usual layouts: how much further
      # into the file it is than a LoROM file's, and the map mode that layout's header says, its
      # fast bit aside. LoROM is first, so a file whose bytes read as a header at both places, as
      # one VBlank builds might by chance, is read as the LoROM cartridge it is.
      HeaderPlace = Data.define(:shift, :map_mode)
      HEADER_PLACES = [HeaderPlace.new(shift: 0, map_mode: LOROM_SLOW),
                       HeaderPlace.new(shift: HIROM_HEADER_SHIFT, map_mode: HIROM_SLOW)].freeze
      FAST_BIT = LOROM_FAST ^ LOROM_SLOW

      # The console a cartridge of this kind is for; whether +bytes+ are one (a header whose
      # checksum and complement agree, at the place of the layout its map mode says); and its
      # title field.
      def self.console = :snes

      def self.header?(bytes) = !header_place_of(bytes).nil?

      # The title field of the header found, or the LoROM place's bytes when none is.
      def self.title_field_of(bytes)
        bytes.byteslice(TITLE_AT + (header_place_of(bytes)&.shift || 0), TITLE_LENGTH)
      end

      # The first of HEADER_PLACES that holds a header of its own layout in +bytes+, or nil.
      def self.header_place_of(bytes)
        HEADER_PLACES.find do |place|
          next false if bytes.bytesize < place.shift + SMALLEST

          complement, checksum = bytes.byteslice(COMPLEMENT_AT + place.shift, 4).unpack("v2")
          (checksum ^ complement) == 0xFFFF && (bytes.getbyte(MAP_MODE_AT + place.shift) & ~FAST_BIT) == place.map_mode
        end
      end

      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.rstrip

      def write(path) = ROM.write_bytes(path, @bytes)

      # HOW MANY FRAMES ITS PASSES TOOK: the cartridge run in the emulator
      # (Diagnostics::SNESProfiler), reported for a person or as JSON. +keys+ are held from
      # power-on, and +settle+ passes run before the +frames+ passes measured.
      #
      # With a +tape+, the tape is played from power-on and +frames+ is a range of its frames, each
      # read by itself (Diagnostics::TapeProfile).
      def profile(format: :human, out: $stdout, frames: Diagnostics::SNESProfiler::FRAMES,
                  settle: nil, keys: [], scene: nil, from: nil, press: [], tape: nil)
        Diagnostics::TapeProfile.refuse_scene!(scene, from, "Super Nintendo")
        Diagnostics::TimeByRoutine.refuse_press!(press, "Super Nintendo")
        if tape
          return Diagnostics::TapeProfile.profile(self, Diagnostics::SNESProfiler, tape: tape, frames: frames, keys: keys,
                                                                                   settle: settle, format: format, out: out)
        end

        result = Diagnostics::SNESProfiler.run(self, frames: frames, settle: settle || Diagnostics::SNESProfiler::SETTLE,
                                                     keys: keys)
        case format
        when :human then Diagnostics::SNESProfiler.render(result, out: out)
        when :json then out.puts(JSON.generate(result.to_h))
        else raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)"
        end
        result
      end

      private

      # A whole number of 32K banks, a power of two of them.
      def padded(bytes)
        size = SMALLEST
        size *= 2 while size < bytes.bytesize
        bytes + ("\xFF".b * (size - bytes.bytesize))
      end

      def write_header(title, save_bytes)
        @bytes[TITLE_AT, TITLE_LENGTH] = title_field_for(title)
        @bytes.setbyte(MAP_MODE_AT, @board.map_mode)
        @bytes.setbyte(CARTRIDGE_TYPE_AT, cartridge_type(save_bytes))
        @bytes.setbyte(ROM_SIZE_AT, kilobyte_power(@bytes.bytesize))
        # A chip's RAM is the cartridge's RAM, and its size is in the extended header instead.
        saved_here = @board.chip_ram_bytes.zero? && !save_bytes.zero?
        @bytes.setbyte(RAM_SIZE_AT, saved_here ? kilobyte_power(save_bytes) : 0)
        @bytes.setbyte(DESTINATION_AT, NORTH_AMERICA)
        @bytes.setbyte(MAKER_AT, @board.chip_ram_bytes.zero? ? 0 : EXTENDED_HEADER)
        @bytes.setbyte(VERSION_AT, 0)
      end

      def cartridge_type(save_bytes)
        if @board.name == :super_fx
          save_bytes.zero? ? SUPER_FX_RAM : SUPER_FX_RAM_BATTERY
        else
          save_bytes.zero? ? ROM_ONLY : ROM_RAM_BATTERY
        end
      end

      # A maker code of "00" (none) and a game code of four spaces (none), so the cartridge
      # claims no real game's code, then the chip's RAM size, its save's bank counted in; the rest
      # of the 16 bytes nought.
      def write_extended_header(save_bytes)
        @bytes[MAKER_CODE_AT, 16] = "\0".b * 16
        @bytes[MAKER_CODE_AT, 2] = "00"
        @bytes[GAME_CODE_AT, 4] = "    "
        @bytes.setbyte(EXPANSION_RAM_AT, kilobyte_power(@board.chip_ram_bytes_with(save_bytes)))
      end

      def kilobyte_power(bytes) = SNESROM.size_byte(bytes)

      # Upper-case letters, digits and spaces, padded with spaces, as the cartridges of the day.
      def title_field_for(title)
        title.to_s.upcase.gsub(/[^A-Z0-9 ]/, " ").byteslice(0, TITLE_LENGTH).b.ljust(TITLE_LENGTH, " ")
      end

      def write_vectors(vectors)
        unknown = vectors.keys - VECTORS.keys
        raise ArgumentError, "a Super Nintendo has no #{unknown.join(', ')} vector" unless unknown.empty?

        reset = vectors.fetch(:reset)
        VECTORS.each do |name, at|
          @bytes[at - 0x8000, 2] = [vectors.fetch(name, reset) & 0xFFFF].pack("v")
        end
      end

      # Every byte added, with the checksum's own four bytes taken as $FFFF and $0000, which add
      # to what any checksum and its complement add to.
      def write_checksum
        @bytes[COMPLEMENT_AT, 4] = [0xFFFF, 0x0000].pack("v2")
        sum = @bytes.sum(16)
        @bytes[COMPLEMENT_AT, 4] = [sum ^ 0xFFFF, sum].pack("v2")
      end
    end
  end
end
