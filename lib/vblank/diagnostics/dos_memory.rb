# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING DOS PROGRAM'S MEMORY, read by the offset its own code uses. A game's numbers live in one data
    # segment, and DOS chose the segment when it loaded the program, so the program says where: its first
    # act is to store its data segment in the Intra-Application Communication Area, the 16 bytes at
    # 0040:00F0 (linear 4F0h) that the PC's designers kept free for programs to talk to each other. A
    # reader takes the segment from there and an address is an offset into it.
    #
    # The headless run (IR::Backends::DOS::HeadlessRun) and the finished-program reader (DOSProbe) both read
    # through this, each handing over the emulator core it holds.
    module DOSMemory
      # Where the program keeps its data segment: 0040:00F0.
      DATA_SEGMENT_AT = 0x4F0

      # A byte beside it that a program started as `GAME.EXE HOLD` sets, to wait at its start until a reader
      # clears it (RubyDOSEmulator::Core::START_GATE_AT, which is the same place). The byte is nought in a
      # PC that nobody reads, and the program never waits there.
      START_GATE_AT = 0x4F2

      module_function

      def read8(core, offset) = bytes(core, offset, 1).getbyte(0)
      def read16(core, offset) = bytes(core, offset, 2).unpack1("v")
      def read32(core, offset) = bytes(core, offset, 4).unpack1("V")

      def write32(core, offset, value) = core.poke(linear(core, offset), [value & 0xFFFF_FFFF].pack("V"))

      def bytes(core, offset, count) = core.peek(linear(core, offset), count)

      # The first +count+ pixels of the picture the game draws in, a palette entry each: its own, in a segment
      # past its data, which the card is sent as each retrace begins (IR::Backends::DOS::Runtime, "THE PICTURE").
      # +after_data+ is how many paragraphs past the data segment the picture is: the game's own, or for a
      # game with sprites, a camera or blocks the one shown, made from it (DOS.picture_shown_after_data).
      def picture(core, count, after_data: IR::Backends::DOS::PICTURE_AFTER_DATA)
        data_segment = core.peek(DATA_SEGMENT_AT, 2).unpack1("v")
        core.peek((data_segment + after_data) << 4, count)
      end

      # The place in the first megabyte of offset +offset+ of the program's data segment.
      def linear(core, offset) = (core.peek(DATA_SEGMENT_AT, 2).unpack1("v") << 4) + offset
    end
  end
end
