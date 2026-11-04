# frozen_string_literal: true

require "json"

module VBlank
  module Cartridge
    # A SEGA GENESIS CARTRIDGE: the code the Genesis lowering linked, with the vectors and the header
    # the console reads in front of it.
    #
    # The 68000 reads its first two long words at power-on: the place the stack starts, and the place
    # to start running. The 62 vectors after them say where it goes when something goes wrong (an
    # address error, a division by zero, an instruction it does not know) and when an interrupt
    # comes: the horizontal blank (level 4) and the vertical blank (level 6) are the ones a game
    # uses. All 64 are four bytes each, big-endian, so the vectors fill the first 256 bytes of the
    # cartridge. A vector a game does not name points where reset does, so a fault restarts the game
    # in place of running off into the weeds.
    #
    # THE HEADER sits at $100, 256 bytes of text and numbers: the console's name (which must start
    # with "SEGA" or a console with the security check will not start the cartridge), the maker, the
    # game's title twice (once as the home market writes it and once as the overseas market does),
    # a serial number, the checksum, which devices the game reads (J is a three-button pad), where the
    # cartridge's ROM and the console's RAM are, the memory the cartridge adds, and which regions it
    # is for. The console itself reads none of it but the "SEGA". An emulator or a flash cart reads
    # all of it to know what the cartridge is, and an emulator that checks reads the checksum:
    # every 16-bit word from $200 to the end of the cartridge, added up and kept to 16 bits.
    #
    # The code starts at $200, where the header ends.
    #
    # References: Sega's Genesis Software Manual; SGDK, src/boot/sega.s (the header and the security
    # check); Genesis Plus GX, core/loadrom.c (what an emulator reads of the header).
    class GenesisROM
      include Console::GenesisHardware

      SMALLEST = 0x10000

      # The place the stack starts, the top of work RAM. The 68000 pushes by taking the pointer down
      # first, so the first push lands in the last long word of RAM.
      STACK_START = WRAM + WRAM_SIZE - 2

      attr_reader :bytes

      # What the build worked out about the cartridge, for the tools that read a running one
      # back, or nil.
      attr_reader :built

      # +image+ is the linked code and data, from $200. +vectors+ names where each vector points, by
      # Console::GenesisHardware::VECTORS's names (:stack is the one that is not an address of code);
      # one not named points where reset does.
      def initialize(image, title:, vectors:, built: nil)
        @built = built
        unknown = vectors.keys - VECTORS.keys
        raise ArgumentError, "a Genesis has no #{unknown.join(', ')} vector" unless unknown.empty?

        @bytes = padded(("\0".b * CODE_AT) + image.b)
        write_vectors(vectors)
        write_header(title)
        write_checksum
      end

      def size = @bytes.bytesize

      # The console a cartridge of this kind is for; whether +bytes+ are one (a cartridge whose header
      # starts with the console's name, SEGA); and its title field.
      def self.console = :genesis

      def self.header?(bytes)
        bytes.bytesize >= CODE_AT && bytes.byteslice(CONSOLE_NAME_AT, 4) == "SEGA"
      end

      def self.title_field_of(bytes) = bytes.byteslice(DOMESTIC_NAME_AT, TITLE_LENGTH)

      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.rstrip

      def write(path) = ROM.write_bytes(path, @bytes)

      # HOW MANY FRAMES ITS PASSES TOOK: the cartridge run in the emulator
      # (Diagnostics::GenesisProfiler), reported for a person or as JSON. +keys+ are held from
      # power-on, and +settle+ passes run before the +frames+ passes measured.
      #
      # With a +tape+, the tape is played from power-on and +frames+ is a range of its frames, each
      # read by itself (Diagnostics::TapeProfile).
      def profile(format: :human, out: $stdout, frames: Diagnostics::GenesisProfiler::FRAMES,
                  settle: nil, keys: [], scene: nil, from: nil, press: [], tape: nil)
        if scene || from
          raise ArgumentError, "a Genesis profile measures the game as it plays from power-on, and cannot be " \
                               "told a #{scene ? 'scene' : 'saved moment'} yet. To fix this, leave out " \
                               "#{scene ? '--scene' : '--from'}, and use --keys and --settle to reach the moment."
        end
        Diagnostics::TimeByRoutine.refuse_press!(press, "Genesis")
        if tape
          return Diagnostics::TapeProfile.profile(self, Diagnostics::GenesisProfiler, tape: tape, frames: frames, keys: keys,
                                                                                      settle: settle, format: format, out: out)
        end

        result = Diagnostics::GenesisProfiler.run(self, frames: frames, settle: settle || Diagnostics::GenesisProfiler::SETTLE,
                                                        keys: keys)
        case format
        when :human then Diagnostics::GenesisProfiler.render(result, out: out)
        when :json then out.puts(JSON.generate(result.to_h))
        else raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)"
        end
        result
      end

      private

      # A power of two in size, of at least SMALLEST, with the empty part of the cartridge as the
      # bytes of an erased chip.
      def padded(bytes)
        size = SMALLEST
        size *= 2 while size < bytes.bytesize
        raise ArgumentError, "a Genesis cartridge holds #{CARTRIDGE_END} bytes, not #{bytes.bytesize}" if size > CARTRIDGE_END

        bytes + ("\xFF".b * (size - bytes.bytesize))
      end

      def write_vectors(vectors)
        reset = vectors.fetch(:reset)
        VECTORS.each do |name, at|
          next if name == :stack

          @bytes[at, 4] = [vectors.fetch(name, reset)].pack("N")
        end
        @bytes[VECTORS.fetch(:stack), 4] = [vectors.fetch(:stack, STACK_START)].pack("N")
      end

      def write_header(title)
        @bytes[CONSOLE_NAME_AT, 16] = "SEGA MEGA DRIVE "
        @bytes[COPYRIGHT_AT, 16] = "(C)VBLK 2026.NOV"
        @bytes[DOMESTIC_NAME_AT, TITLE_LENGTH] = title_field_for(title)
        @bytes[OVERSEAS_NAME_AT, TITLE_LENGTH] = title_field_for(title)
        @bytes[SERIAL_AT, 14] = "GM 00000000-00"
        @bytes[DEVICES_AT, 16] = "J".ljust(16, " ")
        @bytes[ROM_START_AT, 16] = [0, size - 1, WRAM, WRAM + WRAM_SIZE - 1].pack("N4")
        @bytes[0x1B0, 12] = " " * 12 # the memory the cartridge adds: none
        @bytes[0x1BC, 12] = " " * 12 # a modem: none
        @bytes[0x1C8, 40] = " " * 40
        @bytes[REGION_AT, 16] = "JUE".ljust(16, " ")
      end

      # Upper-case letters, digits and spaces, padded with spaces, as the cartridges of the day.
      def title_field_for(title)
        title.to_s.upcase.gsub(/[^A-Z0-9 ]/, " ").byteslice(0, TITLE_LENGTH).b.ljust(TITLE_LENGTH, " ")
      end

      def write_checksum
        @bytes[CHECKSUM_AT, 2] = [@bytes.byteslice(CODE_AT..).unpack("n*").sum & 0xFFFF].pack("n")
      end
    end
  end
end
