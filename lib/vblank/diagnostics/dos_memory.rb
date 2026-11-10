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

      module_function

      def read8(core, offset) = bytes(core, offset, 1).getbyte(0)
      def read16(core, offset) = bytes(core, offset, 2).unpack1("v")
      def read32(core, offset) = bytes(core, offset, 4).unpack1("V")

      def bytes(core, offset, count) = core.peek(linear(core, offset), count)

      # The place in the first megabyte of offset +offset+ of the program's data segment.
      def linear(core, offset) = (core.peek(DATA_SEGMENT_AT, 2).unpack1("v") << 4) + offset
    end
  end
end
