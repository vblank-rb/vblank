# frozen_string_literal: true

module VBlank
  module Cartridge
    # A PLAYSTATION PROGRAM AS A PS-X EXE: the code the PlayStation lowering linked, with the 2048-byte
    # header the console's BIOS (or an emulator, or a loader on a real console) reads in front of it.
    #
    # A PlayStation game ships on a disc, and the disc's SYSTEM.CNF names the program the BIOS loads
    # from it: a PS-X EXE. The same file can be handed to an emulator directly, or sent to a real
    # console over a serial cable by a loader, without a disc at all. That is what this is.
    #
    # THE HEADER (psx-spx, "CDROM File Formats", PS-X EXE), every number four bytes, low byte first:
    #
    #   000h  "PS-X EXE"
    #   010h  where to start running (the entry point)
    #   014h  the value for the global pointer register (gp); 0 here, the runtime sets its own
    #   018h  where in RAM the code goes
    #   01Ch  how many bytes of it, a multiple of 2048
    #   030h  where the stack starts (the loader sets sp to it), and 034h how much is added to that
    #   04Ch  text, which a Sony disc uses for the licence region; here it is the game's title, and never
    #         Sony's text
    #
    # The code follows at 800h, exactly as many bytes as 01Ch gives (an emulator refuses a file longer or
    # shorter than that).
    class PS1EXE
      include Console::PS1Hardware

      MAGIC = "PS-X EXE"
      HEADER_SIZE = 0x800
      BLOCK = 0x800
      ENTRY_AT = 0x10
      GP_AT = 0x14
      LOAD_AT = 0x18
      SIZE_AT = 0x1C
      STACK_AT = 0x30
      TEXT_AT = 0x4C
      TITLE_LENGTH = 64


      attr_reader :bytes

      # What the build worked out about the program, for the tools that read a running one back, or nil.
      attr_reader :built

      # +image+ is the linked code and data, loaded at +load_at+; +entry+ is where it starts.
      def initialize(image, title:, entry:, load_at: EXE_AT, built: nil)
        @built = built
        body = image.b
        body += "\0".b * ((-body.bytesize) % BLOCK)
        raise ArgumentError, "a PlayStation program holds #{PROGRAM_END - load_at} bytes, not #{body.bytesize}" if load_at + body.bytesize > PROGRAM_END

        @bytes = header(title, entry, load_at, body.bytesize) + body
      end

      def size = @bytes.bytesize

      # The console a program of this kind is for; whether +bytes+ are one; and its title field.
      def self.console = :ps1
      def self.header?(bytes) = bytes.bytesize >= HEADER_SIZE && bytes.byteslice(0, MAGIC.bytesize) == MAGIC
      def self.title_field_of(bytes) = bytes.byteslice(TEXT_AT, TITLE_LENGTH)

      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.delete("\0").rstrip

      def write(path) = ROM.write_bytes(path, @bytes)

      # HOW MANY FRAMES ITS PASSES TOOK, AND WHERE THE TIME WENT: the program run in the emulator
      # (Diagnostics::PS1Profiler), reported for a person or as JSON. +keys+ are held from power-on, and
      # +settle+ passes run before the +frames+ passes measured.
      #
      # With a +tape+, the tape is played from power-on and +frames+ is a range of its frames, each read
      # by itself (Diagnostics::TapeProfile), keeping its +routines+ busiest routines, the game's and
      # the runtime's each (three where none is given).
      def profile(format: :human, out: $stdout, frames: Diagnostics::PS1Profiler::FRAMES,
                  settle: nil, keys: [], scene: nil, from: nil, press: [], tape: nil, routines: nil)
        Diagnostics::TapeProfile.refuse_scene!(scene, from, "PlayStation")
        Diagnostics::TimeByRoutine.refuse_press!(press, "PlayStation")
        if tape
          return Diagnostics::TapeProfile.profile(self, Diagnostics::PS1Profiler, tape: tape, frames: frames, keys: keys,
                                                                                  settle: settle, format: format, out: out,
                                                                                  routines: routines)
        end
        Diagnostics::TapeProfile.refuse_routines_without_tape!(routines)

        result = Diagnostics::PS1Profiler.run(self, frames: frames, settle: settle || Diagnostics::PS1Profiler::SETTLE,
                                                    keys: keys)
        case format
        when :human then Diagnostics::PS1Profiler.render(result, out: out)
        when :json then out.puts(JSON.generate(result.to_h))
        else raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)"
        end
        result
      end

      private

      def header(title, entry, load_at, size)
        bytes = "\0".b * HEADER_SIZE
        bytes[0, MAGIC.bytesize] = MAGIC
        bytes[ENTRY_AT, 4] = [entry].pack("V")
        bytes[GP_AT, 4] = [0].pack("V")
        bytes[LOAD_AT, 4] = [load_at].pack("V")
        bytes[SIZE_AT, 4] = [size].pack("V")
        bytes[STACK_AT, 8] = [STACK_TOP, 0].pack("V2")
        text = title.to_s.gsub(/[^ -~]/, " ").byteslice(0, TITLE_LENGTH).b
        bytes[TEXT_AT, text.bytesize] = text
        bytes
      end
    end
  end
end
